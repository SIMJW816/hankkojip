"""AI 배합 제안과 모의·Arduino 계량을 제공하는 Flask 서버."""
import json
import math
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

from flask import Flask, jsonify, request
from dotenv import dotenv_values
from ai_service import AIError, generate_chat, generate_suggestion
from uart_device import DEVICE_PHASES, STATUS_MAX_AGE, UartLink, error_message

ROOT = Path(__file__).parent
DEFAULTS = [('P1', '소금', 'powder'), ('P2', '후추', 'powder'),
            ('P3', '설탕', 'powder'), ('P4', '고춧가루', 'powder'),
            ('L1', '간장', 'liquid'), ('L2', '식초', 'liquid')]
OPEN_JOBS = ('starting', 'running', 'stopping', 'unconfirmed')


class ValidationError(Exception):
    pass


def create_app(database=None, clock=time.time, *, device_mode=None, uart_open=None):
    # 실행 디렉터리와 무관하게 서버 옆 .env를 읽고, 환경변수를 우선합니다.
    settings = {**dotenv_values(ROOT / '.env'), **os.environ}
    mode = device_mode or settings.get('DEVICE_MODE', 'demo')
    if mode not in ('demo', 'uart'):
        raise ValueError('DEVICE_MODE는 demo 또는 uart여야 합니다.')
    uart_mode = mode == 'uart'
    token = settings.get('UART_CONTROL_TOKEN') or ''
    if uart_mode and not re.fullmatch(r'[A-Za-z0-9_-]{32,128}', token):
        raise ValueError('UART_CONTROL_TOKEN에 영문·숫자·밑줄·하이픈 32~128자의 키를 설정하세요.')
    port = settings.get('UART_PORT') or '/dev/serial0'
    baud = int(settings.get('UART_BAUD') or '115200') if uart_mode else None
    if uart_mode and baud <= 0:
        raise ValueError('UART_BAUD는 양의 정수여야 합니다.')
    app = Flask(__name__, static_folder='static', static_url_path='/static')
    app.config.update(MAX_CONTENT_LENGTH=32 * 1024,
                      OPENAI_API_KEY=settings.get('OPENAI_API_KEY') or '',
                      OPENAI_MODEL=settings.get('OPENAI_MODEL') or '')
    ai_lock = threading.Lock()
    db_path = str(database or os.environ.get('DATABASE_PATH', ROOT / 'data' / 'demo.sqlite3'))
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    lock = threading.RLock()
    last_report, last_report_at = None, 0
    pending_start, launched_job = None, None

    @contextmanager
    def connect():
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    with connect() as db:
        db.executescript('''
        CREATE TABLE IF NOT EXISTS slots (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
            available INTEGER NOT NULL DEFAULT 1, revision INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS recipes (
            id TEXT PRIMARY KEY, body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, request_key TEXT UNIQUE NOT NULL,
            started REAL NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL);
        ''')
        for slot, name, kind in DEFAULTS:
            db.execute('INSERT OR IGNORE INTO slots (id,name,kind) VALUES (?,?,?)', (slot, name, kind))

    with connect() as db:
        db.execute("CREATE TABLE IF NOT EXISTS hidden_jobs (id TEXT PRIMARY KEY)")

    def fresh_report():
        if time.monotonic() - last_report_at <= STATUS_MAX_AGE:
            return last_report
        return None

    def slots(db, live=False, *, inventory=False):
        rows = [dict(row) for row in db.execute('SELECT * FROM slots').fetchall()]
        order = [entry[0] for entry in DEFAULTS]
        if uart_mode and live:
            report = fresh_report()
            for row in rows:
                info = report['slots'].get(row['id']) if report else None
                present = info['present'] if info else None
                deferred = info['check_at_center'] if info else False
                sensor = info['has_level_sensor'] if info else None
                row.update(operator_available=row['available'], material_present=present,
                           check_at_center=deferred, has_level_sensor=sensor,
                           available=int(bool(row['available']) and (present is True or deferred or sensor is False)))
                if inventory:
                    row['remaining_pct'] = info['remaining_pct'] if info else None
        return sorted(rows, key=lambda row: order.index(row['id']))

    def control_allowed():
        return not uart_mode or secrets.compare_digest(
            request.headers.get('X-UART-Control-Token', '').encode('utf-8'), token.encode('ascii'))

    def number(value, label, low, high):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValidationError(f'{label}은 숫자로 입력해 주세요.')
        if not low <= value <= high or not math.isfinite(value):
            raise ValidationError(f'{label}은 {low}~{high} 범위여야 합니다.')
        return value

    def text(value, label, limit=80):
        if not isinstance(value, str) or not value.strip() or len(value.strip()) > limit:
            raise ValidationError(f'{label}을 1~{limit}자로 입력해 주세요.')
        return value.strip()

    def payload():
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            raise ValidationError('JSON 객체를 보내 주세요.')
        return body

    def validate_recipe(body, db, manufacturing=False):
        name = text(body.get('name'), '레시피 이름')
        servings = number(body.get('servings'), '인분', 1, 20)
        if int(servings) != servings:
            raise ValidationError('인분은 정수여야 합니다.')
        mode = body.get('mode', 'CUSTOM')
        if mode not in ('CUSTOM', 'DEMO', 'AI'):
            raise ValidationError('지원하지 않는 레시피 모드입니다.')
        items = body.get('items')
        if not isinstance(items, list) or not 1 <= len(items) <= 6:
            raise ValidationError('재료를 1~6개 선택해 주세요.')
        registered = {s['id']: s for s in slots(db)}
        clean, seen = [], set()
        for item in items:
            if not isinstance(item, dict):
                raise ValidationError('재료 형식이 올바르지 않습니다.')
            slot_id = item.get('slot')
            if not isinstance(slot_id, str) or slot_id not in registered or slot_id in seen:
                raise ValidationError('미등록 슬롯 또는 중복 재료가 있습니다.')
            seen.add(slot_id)
            slot = registered[slot_id]
            if not slot['name'] or item.get('name') != slot['name'] or item.get('revision') != slot['revision'] or item.get('kind') != slot['kind']:
                raise ValidationError('슬롯 정보가 변경되었습니다. 현재 재료로 배합을 다시 작성해 주세요.')
            grams = number(item.get('grams'), '재료 중량(g)', 0.1, 100)
            if manufacturing and not slot['available']:
                raise ValidationError(f'{slot["name"]}: 재료가 부족합니다.')
            clean.append(dict(slot=slot_id, name=slot['name'], kind=slot['kind'], revision=slot['revision'], grams=round(grams, 2)))
        if sum(i['grams'] for i in clean) > 300:
            raise ValidationError('데모의 총 중량 한계는 300g입니다.')
        favorite = body.get('favorite', False)
        if not isinstance(favorite, bool):
            raise ValidationError('즐겨찾기는 참/거짓 값이어야 합니다.')
        return dict(name=name, servings=int(servings), mode=mode, items=clean, favorite=favorite)

    def validate_ai_result(result, snapshot, servings):
        """AI 배합을 현재 등록된 슬롯과 서버의 데모 기준으로 검증합니다."""
        try:
            if not isinstance(result, dict) or type(result.get('ready')) is not bool:
                raise ValidationError('AI 응답 상태가 올바르지 않습니다.')
            notice = text(result.get('message'), 'AI 설명', 1500)
            missing = result.get('missing')
            if not isinstance(missing, list) or len(missing) > 20:
                raise ValidationError('부족 재료 형식이 올바르지 않습니다.')
            missing = [text(name, '부족 재료', 80) for name in missing]
            if missing:
                notice += '\n부족한 재료: ' + ', '.join(missing)
            raw_items = result.get('items')
            if not isinstance(raw_items, list) or len(raw_items) > 6:
                raise ValidationError('배합 형식이 올바르지 않습니다.')
            if not result['ready']:
                if raw_items:
                    raise ValidationError('미완성 배합에 재료가 포함되어 있습니다.')
                return None, notice, missing
            servings = number(servings, '인분', 1, 20)
            if int(servings) != servings:
                raise ValidationError('인분은 정수여야 합니다.')
            available = {s['id']: s for s in snapshot if s['name'] and s['available']}
            items = []
            for item in raw_items:
                if not isinstance(item, dict) or not isinstance(item.get('slot'), str) or item['slot'] not in available:
                    raise ValidationError('사용 불가능한 슬롯이 포함되어 있습니다.')
                slot = available[item['slot']]
                items.append(dict(slot=slot['id'], name=slot['name'], kind=slot['kind'],
                                  revision=slot['revision'], grams=item.get('grams')))
            with lock, connect() as db:
                if slots(db, live=True) != snapshot:
                    raise AIError('생성 중 재료가 변경되었습니다. 현재 재료로 다시 요청해 주세요.', 409)
                recipe = validate_recipe(dict(name=result.get('name'), servings=int(servings),
                                              mode='AI', items=items), db, manufacturing=True)
            return recipe, notice, missing
        except ValidationError:
            raise AIError('AI 배합 검증에 실패했습니다. 재료 또는 중량이 올바르지 않아 사용할 수 없습니다.') from None

    def update_job(db, row):
        job = json.loads(row['body'])
        if not job.get('demo', True) or row['status'] != 'running':
            return job
        elapsed = max(0, clock() - row['started'])
        duration = 2.5
        for idx, item in enumerate(job['items']):
            fraction = min(1, max(0, (elapsed - idx * duration) / duration))
            item['actual'] = round(item['grams'] * fraction, 2)
            item['done'] = fraction >= 1
        job['progress'] = min(100, round(elapsed / (len(job['items']) * duration) * 100))
        if all(i['done'] for i in job['items']):
            job['status'] = 'completed'
            job['finished'] = clock()
        db.execute('UPDATE jobs SET status=?,body=? WHERE id=?', (job['status'], json.dumps(job, ensure_ascii=False), job['id']))
        return job

    def open_jobs(db):
        rows = db.execute('SELECT * FROM jobs WHERE status IN (?,?,?,?)', OPEN_JOBS).fetchall()
        jobs = [update_job(db, row) for row in rows]
        return [job for job in jobs if job['status'] in OPEN_JOBS]

    def device_recipe_error(report, items):
        if not report or not report['ready']:
            return 'Arduino가 계량할 준비가 되지 않았습니다. 연결 상태와 빈 컵을 확인해 주세요.'
        if sum(item['grams'] for item in items) > report['max_total_g']:
            return f'장치의 총 목표 중량 한계는 {report["max_total_g"]:g}g입니다.'
        for item in items:
            limits = report['slots'].get(item['slot'])
            if limits is None:
                return f'{item["slot"]} 슬롯의 배출기가 설정되어 있지 않습니다.'
            if limits['has_level_sensor'] and not limits['check_at_center']:
                if limits['present'] is None:
                    return f'{item["name"]}: 장치에서 재료의 잔량 센서를 확인할 수 없습니다.'
                if not limits['present']:
                    return f'{item["name"]}: 장치에서 재료 부족을 감지했습니다.'
            if not limits['min_g'] <= item['grams'] <= limits['max_g']:
                return f'{item["name"]}: 장치 허용 범위는 {limits["min_g"]:g}~{limits["max_g"]:g}입니다.'
        return None

    def save_job(db, job):
        body = json.dumps(job, ensure_ascii=False)
        db.execute('UPDATE jobs SET status=?,body=? WHERE id=? AND body<>?',
                   (job['status'], body, job['id'], body))

    def finish_error(job, code, confirmed):
        job.update(status='error', phase=None, live_g=None, current_slot=None,
                   error_code=code, error=error_message(code), stop_confirmed=confirmed, finished=clock())

    def receive_uart(report):
        """장치 상태를 기록하고, 필요하면 한 번 보낼 시작/정지 명령을 반환합니다."""
        nonlocal last_report, last_report_at, pending_start, launched_job
        with lock, connect() as db:
            last_report, last_report_at = report, time.monotonic()
            job = next((job for job in open_jobs(db) if not job.get('demo', True)), None)
            if report is None:
                pending_start, launched_job = None, None
                if job and job['status'] != 'unconfirmed':
                    if job['command_sent']:
                        job.update(status='unconfirmed', stop_confirmed=False, live_g=None,
                                   error_code='LINK_LOST', error=error_message('LINK_LOST'))
                    else:
                        finish_error(job, 'LINK_LOST', True)
                    save_job(db, job)
                return None

            measured = report['job']
            active_on_board = measured is not None and measured['phase'] in DEVICE_PHASES
            if not report['safe'] and not active_on_board:
                pending_start, launched_job = None, None
                if job:
                    if job['command_sent']:
                        job.update(status='unconfirmed', stop_confirmed=False, live_g=None,
                                   error_code='OUTPUT', error=error_message('OUTPUT'))
                    else:
                        finish_error(job, 'OUTPUT', True)
                    save_job(db, job)
                return None
            if active_on_board and (job is None or job['id'] != measured['id']):
                return dict(command='STOP', job_id=measured['id'])
            if job is None:
                return None

            if pending_start == job['id']:
                pending_start = None
                if device_recipe_error(report, job['items']):
                    finish_error(job, 'NOT_READY', True)
                    save_job(db, job)
                    return None
                job['command_sent'] = True
                launched_job = job['id']
                save_job(db, job)
                return dict(command='START', job_id=job['id'],
                            items=[dict(slot=i['slot'], target_g=i['grams']) for i in job['items']])

            if measured is None or measured['id'] != job['id']:
                finish_error(job, 'JOB_LOST', not job['command_sent'])
                save_job(db, job)
                launched_job = None
                return None

            expected = [(i['slot'], i['grams']) for i in job['items']]
            actual = [(i['slot'], i['target_g']) for i in measured['items']]
            if expected != actual and not (report['safe'] and measured['phase'] == 'error' and not actual):
                if report['safe']:
                    finish_error(job, 'INVALID_REPORT', True)
                else:
                    job.update(status='stopping', live_g=None, error_code='INVALID_REPORT',
                               error=error_message('INVALID_REPORT'))
                save_job(db, job)
                return None if report['safe'] else dict(command='STOP', job_id=job['id'])

            for item, result in zip(job['items'], measured['items']):
                item.update(actual=result['actual_g'], done=result['done'])
            done = sum(i['done'] for i in job['items'])
            phase = measured['phase']
            job.update(phase=phase, current_slot=measured['current_slot'], live_g=measured['live_g'],
                       progress=100 if phase == 'completed' else min(99, 100 * done // len(job['items'])))
            if phase not in DEVICE_PHASES:
                launched_job = None
                if phase == 'error' or job.get('error_code') in ('LINK_LOST', 'INVALID_REPORT'):
                    finish_error(job, measured['error_code'] or job.get('error_code') or 'UNKNOWN', True)
                else:
                    job.update(status=phase, stop_confirmed=True, finished=clock())
                save_job(db, job)
                return None

            stopping = (job['status'] in ('stopping', 'unconfirmed')
                        or job['id'] != launched_job or phase == 'stopping')
            job['status'] = 'stopping' if stopping else 'running'
            save_job(db, job)
            if stopping and phase != 'stopping':
                return dict(command='STOP', job_id=job['id'])
            return None

    @app.errorhandler(ValidationError)
    def invalid(error):
        return jsonify(error=str(error)), 400

    @app.errorhandler(AIError)
    def ai_error(error):
        return jsonify(error=str(error)), error.status

    @app.errorhandler(413)
    def too_large(error):
        return jsonify(error='요청 데이터가 너무 큽니다.'), 413

    @app.get('/')
    def index():
        return app.send_static_file('index.html')

    @app.get('/api/state')
    def state():
        with lock, connect() as db:
            rows = db.execute('SELECT * FROM jobs WHERE id NOT IN (SELECT id FROM hidden_jobs) ORDER BY started DESC').fetchall()
            jobs = [update_job(db, r) for r in rows]
            recipes = [json.loads(r['body']) for r in db.execute('SELECT body FROM recipes ORDER BY rowid DESC')]
            report = fresh_report()
            device = dict(mode=mode, connected=report is not None)
            if uart_mode:
                device.update(ready=bool(report and report['ready']
                                        and not any(j['status'] in OPEN_JOBS for j in jobs)),
                              max_total_g=report['max_total_g'] if report else None,
                              error=error_message(report['error_code']) if report and report['error_code'] else None)
            return jsonify(slots=slots(db, live=True, inventory=True), recipes=recipes, jobs=jobs, device=device,
                           ai={'configured': bool(app.config['OPENAI_API_KEY'] and app.config['OPENAI_MODEL'])})

    @app.put('/api/slots/<slot_id>')
    def edit_slot(slot_id):
        if not control_allowed():
            return jsonify(error='장치 제어 키를 확인해 주세요.'), 403
        body = payload()
        name = body.get('name')
        if not isinstance(name, str) or len(name.strip()) > 30:
            raise ValidationError('재료 이름은 30자 이내로 입력해 주세요.')
        available = body.get('available')
        if not isinstance(available, bool):
            raise ValidationError('재료 상태를 선택해 주세요.')
        with lock, connect() as db:
            if open_jobs(db):
                raise ValidationError('제조 중에는 재료 정보를 변경할 수 없습니다.')
            slot = db.execute('SELECT * FROM slots WHERE id=?', (slot_id,)).fetchone()
            if not slot:
                return jsonify(error='슬롯을 찾을 수 없습니다.'), 404
            revision = slot['revision'] + (name.strip() != slot['name'])
            db.execute('UPDATE slots SET name=?,available=?,revision=? WHERE id=?',
                       (name.strip(), int(available), revision, slot_id))
        return jsonify(ok=True)

    @app.post('/api/suggestions')
    def suggestion():
        body = payload()
        dish = text(body.get('dish'), '음식 이름', 40)
        servings = number(body.get('servings'), '인분', 1, 20)
        taste = body.get('taste', 'balanced')
        if taste not in ('balanced', 'less-salt', 'spicy'):
            raise ValidationError('맛 취향을 선택해 주세요.')
        if int(servings) != servings:
            raise ValidationError('인분은 정수여야 합니다.')
        with lock, connect() as db:
            snapshot = slots(db, live=True)
        available = {s['id']: s for s in snapshot if s['name'] and s['available']}
        if not available:
            raise ValidationError('사용 가능한 재료를 먼저 등록하거나 보충해 주세요.')
        if not ai_lock.acquire(blocking=False):
            raise AIError('다른 AI 배합을 생성 중입니다. 잠시 후 다시 요청해 주세요.', 429)
        try:
            result = generate_suggestion(app.config['OPENAI_API_KEY'], app.config['OPENAI_MODEL'],
                                         dish, int(servings), taste, snapshot)
        finally:
            ai_lock.release()
        recipe, notice, missing = validate_ai_result(result, snapshot, servings)
        return jsonify(recipe=recipe, notice=notice, missing=missing)

    @app.post('/api/ai/chat')
    def chat():
        body = payload()
        message = text(body.get('message'), '메시지', 500)
        history = body.get('history', [])
        if not isinstance(history, list) or len(history) > 12:
            raise ValidationError('대화 내역은 최근 12개 메시지까지 보낼 수 있습니다.')
        clean_history = []
        for entry in history:
            if not isinstance(entry, dict) or entry.get('role') not in ('user', 'assistant'):
                raise ValidationError('대화 내역 형식이 올바르지 않습니다.')
            clean_history.append(dict(role=entry['role'], content=text(entry.get('content'), '대화 내용', 1500)))
        if sum(len(entry['content']) for entry in clean_history) > 6000:
            raise ValidationError('대화 내역이 너무 깁니다. 새 대화를 시작해 주세요.')
        current = body.get('current_recipe')
        if current is not None and not isinstance(current, dict):
            raise ValidationError('현재 배합 형식이 올바르지 않습니다.')
        with lock, connect() as db:
            snapshot = slots(db, live=True)
            if current is not None:
                try:
                    current = validate_recipe(current, db, manufacturing=True)
                except ValidationError:
                    raise AIError('이전 배합의 재료가 변경되었거나 부족합니다. 새 대화에서 다시 제안받아 주세요.', 409) from None
        if not ai_lock.acquire(blocking=False):
            raise AIError('다른 AI 배합을 생성 중입니다. 잠시 후 다시 요청해 주세요.', 429)
        try:
            result = generate_chat(app.config['OPENAI_API_KEY'], app.config['OPENAI_MODEL'],
                                   message, clean_history, current, snapshot)
        finally:
            ai_lock.release()
        with lock, connect() as db:
            if slots(db, live=True) != snapshot:
                raise AIError('대화 중 재료가 변경되었습니다. 현재 재료로 다시 요청해 주세요.', 409)
        if not isinstance(result, dict):
            raise AIError('AI 대화 응답 형식이 올바르지 않습니다.')
        foods = result.get('foods')
        if not isinstance(foods, list) or len(foods) > 3:
            raise AIError('AI 음식 추천 형식이 올바르지 않습니다.')
        try:
            foods = [text(food, '추천 음식', 80) for food in foods]
        except ValidationError:
            raise AIError('AI 음식 추천 형식이 올바르지 않습니다.') from None
        recipe, notice, missing = validate_ai_result(result, snapshot, result.get('servings'))
        return jsonify(message=notice, recipe=recipe, foods=foods, missing=missing)

    @app.post('/api/recipes')
    @app.put('/api/recipes/<recipe_id>')
    def save_recipe(recipe_id=None):
        body = payload()
        with lock, connect() as db:
            if recipe_id and not db.execute('SELECT id FROM recipes WHERE id=?', (recipe_id,)).fetchone():
                return jsonify(error='레시피를 찾을 수 없습니다.'), 404
            recipe = validate_recipe(body, db)
            recipe['id'] = recipe_id or uuid.uuid4().hex
            db.execute('INSERT INTO recipes VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
                       (recipe['id'], json.dumps(recipe, ensure_ascii=False)))
        return jsonify(recipe), 200 if recipe_id else 201

    @app.patch('/api/recipes/<recipe_id>/favorite')
    def favorite_recipe(recipe_id):
        body = payload()
        if set(body) != {'favorite'} or not isinstance(body['favorite'], bool):
            raise ValidationError('즐겨찾기는 참/거짓 값만 보내 주세요.')
        with lock, connect() as db:
            row = db.execute('SELECT body FROM recipes WHERE id=?', (recipe_id,)).fetchone()
            if not row:
                return jsonify(error='레시피를 찾을 수 없습니다.'), 404
            recipe = json.loads(row['body'])
            recipe['favorite'] = body['favorite']
            db.execute('UPDATE recipes SET body=? WHERE id=?',
                       (json.dumps(recipe, ensure_ascii=False), recipe_id))
        return jsonify(recipe)

    @app.delete('/api/recipes/<recipe_id>')
    def delete_recipe(recipe_id):
        with lock, connect() as db:
            count = db.execute('DELETE FROM recipes WHERE id=?', (recipe_id,)).rowcount
        return (jsonify(ok=True), 200) if count else (jsonify(error='레시피를 찾을 수 없습니다.'), 404)

    @app.post('/api/jobs')
    def start_job():
        nonlocal pending_start
        if not control_allowed():
            return jsonify(error='장치 제어 키를 확인해 주세요.'), 403
        body = payload()
        if body.get('approved') is not True:
            raise ValidationError('배합을 확인한 뒤 제조를 승인해 주세요.')
        if body.get('device_mode', 'demo') != mode:
            return jsonify(error='계량 모드가 바뀌었습니다. 배합과 계량 모드를 다시 확인해 주세요.'), 409
        key = text(body.get('request_key'), '작업 요청 키', 100)
        with lock, connect() as db:
            previous = db.execute('SELECT * FROM jobs WHERE request_key=?', (key,)).fetchone()
            if previous:
                return jsonify(update_job(db, previous))
            if open_jobs(db):
                return jsonify(error='진행 중이거나 정지 확인을 기다리는 제조가 있습니다.'), 409
            recipe = validate_recipe(body.get('recipe', {}) if isinstance(body.get('recipe'), dict) else {}, db, manufacturing=True)
            if uart_mode:
                report = fresh_report()
                if error := device_recipe_error(report, recipe['items']):
                    return jsonify(error=error), 503 if not report or not report['ready'] else 400
            job = dict(recipe, id=uuid.uuid4().hex, started=clock(),
                       status='starting' if uart_mode else 'running', progress=0, demo=not uart_mode)
            job['items'] = [dict(i, actual=None if uart_mode else 0, done=False) for i in recipe['items']]
            if uart_mode:
                job.update(command_sent=False, stop_confirmed=None)
                pending_start = job['id']
            db.execute('INSERT INTO jobs VALUES (?,?,?,?,?)', (job['id'], key, job['started'], job['status'], json.dumps(job, ensure_ascii=False)))
        return jsonify(job), 201

    @app.delete('/api/jobs/<job_id>')
    @app.post('/api/jobs/<job_id>/recipe')
    def history_action(job_id):
        with lock, connect() as db:
            row = db.execute('SELECT * FROM jobs WHERE id=? AND id NOT IN (SELECT id FROM hidden_jobs)', (job_id,)).fetchone()
            if not row:
                return jsonify(error='제조 이력을 찾을 수 없습니다.'), 404
            job = update_job(db, row)
            if job['status'] in OPEN_JOBS:
                return jsonify(error='제조가 끝나거나 중단된 뒤 다시 시도해 주세요.'), 409
            if request.method == 'DELETE':
                # Keep the request key so a retry cannot manufacture again.
                db.execute('INSERT INTO hidden_jobs VALUES (?)', (job_id,))
                return jsonify(ok=True)
            recipe = validate_recipe(dict(job, favorite=False), db)
            recipe['id'] = uuid.uuid4().hex
            db.execute('INSERT INTO recipes VALUES (?,?)',
                       (recipe['id'], json.dumps(recipe, ensure_ascii=False)))
        return jsonify(recipe), 201

    @app.post('/api/jobs/<job_id>/stop')
    def stop_job(job_id):
        nonlocal pending_start
        if not control_allowed():
            return jsonify(error='장치 제어 키를 확인해 주세요.'), 403
        with lock, connect() as db:
            row = db.execute('SELECT * FROM jobs WHERE id=?', (job_id,)).fetchone()
            if not row:
                return jsonify(error='작업을 찾을 수 없습니다.'), 404
            job = update_job(db, row)
            if job.get('demo', True) and job['status'] == 'running':
                job.update(status='stopped', finished=clock())
                save_job(db, job)
            elif job['status'] in OPEN_JOBS and not job.get('demo', True):
                if not uart_mode:
                    return jsonify(error='이 실제 제조의 정지를 확인하려면 UART 모드로 연결해 주세요.'), 503
                if not job['command_sent']:
                    pending_start = None
                    job.update(status='stopped', finished=clock(), stop_confirmed=True)
                elif job['status'] != 'unconfirmed':
                    job['status'] = 'stopping'
                save_job(db, job)
        return jsonify(job)

    @app.after_request
    def headers(response):
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
        if request.path.startswith('/api/'):
            response.headers['Cache-Control'] = 'no-store'
        return response

    if uart_mode:
        link = UartLink(port, baud, receive_uart, opener=uart_open)
        app.extensions['uart_link'] = link
        link.start()
    return app


if __name__ == '__main__':
    app = create_app()
    try:
        app.run(host=os.environ.get('HOST', '127.0.0.1'), port=int(os.environ.get('PORT', 8000)), debug=False)
    finally:
        if 'uart_link' in app.extensions:
            app.extensions['uart_link'].close()
