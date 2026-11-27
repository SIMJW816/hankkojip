import json
import os
import secrets
import sqlite3
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

from app import create_app
from uart_device import DEVICE_PHASES, decode_status


class FakeArduino:
    """가상 포트에서 명령을 읽고, 테스트가 지정한 장치 상태를 보고합니다."""

    def __init__(self):
        self.lock = threading.Lock()
        self.buffer = bytearray()
        self.online = True
        self.job = None
        self.output_fault = False
        self.present = True
        self.has_level_sensor = True
        self.check_at_center = False
        self.remaining_pct = None
        self.start_phase = 'dispensing'
        self.commands = []

    def __enter__(self):
        self.buffer.clear()
        return self

    def __exit__(self, *args):
        return False

    def open(self):
        return self

    @property
    def in_waiting(self):
        return len(self.buffer)

    def read(self, size):
        if not self.buffer:
            time.sleep(0.005)
        size = min(size, 32)
        data = bytes(self.buffer[:size])
        del self.buffer[:size]
        return data

    def write(self, data):
        frame = json.loads(data)
        with self.lock:
            command = frame['command']
            if command == 'GET_STATUS' and self.online:
                active = self.job and self.job['phase'] in DEVICE_PHASES
                safe = not active and not self.output_fault
                status = dict(v=1, seq=frame['seq'], session=frame['session'], event='STATUS',
                              ready=safe, safe=safe, max_total_g=4, job=self.job,
                              slots={'P1': dict(min_g=1, max_g=4, present=self.present)})
                if self.check_at_center:
                    status['slots']['P1']['check_at_center'] = True
                if not self.has_level_sensor:
                    status['slots']['P1']['has_level_sensor'] = False
                if self.remaining_pct is not None:
                    status['slots']['P1']['remaining_pct'] = self.remaining_pct
                if self.output_fault:
                    status['error_code'] = 'OUTPUT'
                self.buffer.extend(b'{broken\n')
                self.buffer.extend(json.dumps(status).encode() + b'\n')
            elif command == 'START':
                self.commands.append(deepcopy(frame))
                self.job = dict(id=frame['job_id'], phase=self.start_phase,
                                current_slot=frame['items'][0]['slot'],
                                items=[dict(i, actual_g=None, done=False) for i in frame['items']])
            elif command == 'STOP':
                self.commands.append(deepcopy(frame))
                if self.job and self.job['id'] == frame['job_id']:
                    self.job.update(phase='stopping')
        return len(data)

    def received(self, command):
        with self.lock:
            return [frame for frame in self.commands if frame['command'] == command]

    def finish(self, phase, grams=None, error=None):
        with self.lock:
            self.job.update(phase=phase, error_code=error)
            self.job['items'][0].update(actual_g=grams, done=phase == 'completed')


class UartTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.database = Path(self.tmp.name) / 'uart.sqlite3'
        self.board = FakeArduino()
        self.headers = {'X-UART-Control-Token': secrets.token_urlsafe(24)}
        env = patch.dict(os.environ, UART_CONTROL_TOKEN=next(iter(self.headers.values())))
        env.start()
        self.addCleanup(env.stop)
        self.connect_app()

    def connect_app(self, ready=True):
        self.app = create_app(self.database, device_mode='uart', uart_open=self.board.open)
        self.link = self.app.extensions['uart_link']
        self.addCleanup(self.link.close)
        self.client = self.app.test_client()
        if ready:
            self.until(lambda: self.client.get('/api/state').json['device']['ready'])

    def until(self, condition):
        deadline = time.monotonic() + 4
        while not condition():
            self.assertLess(time.monotonic(), deadline, 'Arduino 상태 변경을 받지 못했습니다.')
            time.sleep(0.01)

    def recorded_job(self):
        # 화면의 상태 조회 없이 UART 스레드가 제조 이력을 기록하는지 확인합니다.
        with closing(sqlite3.connect(self.database)) as db:
            row = db.execute('SELECT body FROM jobs ORDER BY rowid DESC LIMIT 1').fetchone()
        return json.loads(row[0]) if row else {}

    def recipe(self, grams=2.5):
        slot = self.client.get('/api/state').json['slots'][0]
        return dict(name='실계량 시험', servings=2, mode='CUSTOM',
                    items=[dict(slot='P1', grams=grams, **{k: slot[k] for k in ('name', 'kind', 'revision')})])

    def start(self, key='one', grams=2.5, **changes):
        payload = dict(approved=True, device_mode='uart', request_key=key, recipe=self.recipe(grams))
        headers = changes.pop('headers', self.headers)
        payload.update(changes)
        return self.client.post('/api/jobs', json=payload, headers=headers)

    def start_dispensing(self):
        response = self.start()
        self.assertEqual(response.status_code, 201, response.json)
        self.until(lambda: self.recorded_job().get('status') == 'running')
        return response.json['id']

    def test_start_requires_control_key_mode_and_live_device_limits(self):
        self.assertEqual(self.start(headers={}).status_code, 403)
        self.assertEqual(self.start(approved=False).status_code, 400)
        self.assertEqual(self.start(device_mode='demo').status_code, 409)
        self.assertEqual(self.start(grams=5).status_code, 400)
        with self.board.lock:
            self.board.present = False
        self.until(lambda: self.client.get('/api/state').json['slots'][0]['material_present'] is False)
        self.assertEqual(self.start().status_code, 400)
        with self.board.lock:
            self.board.online = False
        self.until(lambda: not self.client.get('/api/state').json['device']['connected'])
        self.assertEqual(self.start().status_code, 503)
        self.assertEqual(self.board.received('START'), [])

    def test_shared_tof_rechecks_instead_of_trusting_the_last_reading(self):
        with self.board.lock:
            self.board.present = None
            self.board.remaining_pct = 62
            self.board.check_at_center = True
            self.board.start_phase = 'positioning'
        self.until(lambda: self.client.get('/api/state').json['slots'][0]['check_at_center'])
        slot = self.client.get('/api/state').json['slots'][0]
        self.assertIsNone(slot['material_present'])
        self.assertEqual(slot['remaining_pct'], 62)
        self.assertEqual(slot['available'], 1)
        self.start_dispensing()
        self.assertEqual(self.recorded_job()['phase'], 'positioning')
        with self.board.lock:
            self.board.job['phase'] = 'checking'
        self.until(lambda: self.recorded_job()['phase'] == 'checking')
        self.board.finish('error', error='MATERIAL_SENSOR')
        self.until(lambda: self.recorded_job().get('status') == 'error')
        self.assertEqual(self.recorded_job()['error_code'], 'MATERIAL_SENSOR')
        self.assertIsNone(self.recorded_job()['items'][0]['actual'])
        self.assertEqual(len(self.board.received('START')), 1)

    def test_unknown_sensor_blocks_a_slot_without_a_center_check(self):
        with self.board.lock:
            self.board.present = None
        self.until(lambda: self.client.get('/api/state').json['slots'][0]['material_present'] is None)
        self.assertEqual(self.client.get('/api/state').json['slots'][0]['available'], 0)
        self.assertEqual(self.start().status_code, 400)
        self.assertEqual(self.board.received('START'), [])

    def test_powder_without_level_sensor_can_start_and_report_no_flow(self):
        with self.board.lock:
            self.board.present = None
            self.board.has_level_sensor = False
        self.until(lambda: self.client.get('/api/state').json['slots'][0]['has_level_sensor'] is False)
        slot = self.client.get('/api/state').json['slots'][0]
        self.assertEqual(slot['available'], 1)
        self.assertIsNone(slot['material_present'])
        self.assertIsNone(slot['remaining_pct'])
        self.start_dispensing()
        self.board.finish('error', error='NO_FLOW')
        self.until(lambda: self.recorded_job().get('status') == 'error')
        self.assertEqual(self.recorded_job()['error_code'], 'NO_FLOW')
        self.assertIsNone(self.recorded_job()['items'][0]['actual'])
        self.assertEqual(len(self.board.received('START')), 1)

    def test_status_rejects_invalid_remaining_percentage_and_liquid_center_check(self):
        status = dict(ready=True, safe=True, max_total_g=4, job=None,
                      slots={'P1': dict(min_g=1, max_g=4, present=True, remaining_pct=101)})
        with self.assertRaises(ValueError):
            decode_status(status)
        status['slots'] = {'L1': dict(min_g=1, max_g=4, present=None, check_at_center=True)}
        with self.assertRaises(ValueError):
            decode_status(status)

    def test_only_powder_can_explicitly_report_no_level_sensor(self):
        status = dict(ready=True, safe=True, max_total_g=4, job=None,
                      slots={'L1': dict(min_g=1, max_g=4, present=None, has_level_sensor=False)})
        with self.assertRaises(ValueError):
            decode_status(status)

    def test_parallel_start_is_unique_and_uart_actual_is_saved(self):
        recipe = self.recipe()

        def submit(key):
            with self.app.test_client() as client:
                return client.post('/api/jobs',
                                   json=dict(approved=True, device_mode='uart', request_key=key, recipe=recipe),
                                   headers=self.headers)

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(submit, ('one', 'two')))
        self.assertEqual(sorted(r.status_code for r in results), [201, 409])
        winner = next(r for r in results if r.status_code == 201).json
        self.assertFalse(winner['demo'])
        self.assertIsNone(winner['items'][0]['actual'])
        self.until(lambda: len(self.board.received('START')) == 1)
        command = self.board.received('START')[0]
        self.assertEqual(command['job_id'], winner['id'])
        self.assertEqual(command['items'], [{'slot': 'P1', 'target_g': 2.5}])
        self.assertGreater(command['ack'], 0)
        self.board.finish('completed', 2.46)
        self.until(lambda: self.recorded_job()['status'] == 'completed')
        saved = self.recorded_job()
        self.assertEqual(saved['items'][0]['actual'], 2.46)
        self.assertEqual(saved['items'][0]['grams'], 2.5)
        self.assertEqual(saved['progress'], 100)
        self.assertEqual(self.start(key='one' if results[0].status_code == 201 else 'two').json['id'], winner['id'])
        self.assertEqual(len(self.board.received('START')), 1)

    def test_stop_preserves_partial_result_and_waits_for_board(self):
        job_id = self.start_dispensing()
        path = '/api/jobs/' + job_id
        self.assertEqual(self.client.post(path + '/stop').status_code, 403)
        stopped = self.client.post(path + '/stop', headers=self.headers).json
        self.assertEqual(stopped['status'], 'stopping')
        self.assertIsNone(stopped['stop_confirmed'])
        self.assertEqual(self.client.delete(path).status_code, 409)
        self.assertEqual(self.client.post(path + '/recipe').status_code, 409)
        self.until(lambda: len(self.board.received('STOP')) == 1)
        self.board.finish('stopped', 0.63)
        self.until(lambda: self.recorded_job()['status'] == 'stopped')
        self.assertEqual(self.recorded_job()['items'][0]['actual'], 0.63)
        self.assertTrue(self.recorded_job()['stop_confirmed'])
        self.assertEqual(self.client.post(path + '/recipe').json['items'][0]['grams'], 2.5)

    def test_link_failure_blocks_new_start_and_recovers_without_replay(self):
        job_id = self.start_dispensing()
        with self.board.lock:
            self.board.online = False
        self.until(lambda: self.recorded_job()['status'] == 'unconfirmed')
        self.assertFalse(self.recorded_job()['stop_confirmed'])
        self.assertEqual(self.start('other').status_code, 409)
        self.assertEqual(self.start().json['id'], job_id)

        with self.board.lock:
            self.board.online = True
        self.until(lambda: len(self.board.received('STOP')) == 1)
        self.board.finish('error', error='WATCHDOG')
        self.until(lambda: self.recorded_job()['status'] == 'error')
        self.assertTrue(self.recorded_job()['stop_confirmed'])
        self.assertIsNone(self.recorded_job()['items'][0]['actual'])
        self.assertEqual(len(self.board.received('START')), 1)

    def test_server_restart_does_not_resume_a_manufacturing_job(self):
        job_id = self.start_dispensing()
        self.link.close()
        self.connect_app(ready=False)
        self.until(lambda: len(self.board.received('STOP')) == 1)
        self.assertEqual(self.board.received('STOP')[0]['job_id'], job_id)
        self.board.finish('error', error='SESSION_CHANGED')
        self.until(lambda: self.recorded_job()['status'] == 'error')
        self.assertEqual(len(self.board.received('START')), 1)

    def test_output_fault_keeps_stop_unconfirmed(self):
        self.start_dispensing()
        with self.board.lock:
            self.board.output_fault = True
            self.board.job.update(phase='error', error_code='OUTPUT')
        self.until(lambda: self.recorded_job()['status'] == 'unconfirmed')
        self.assertEqual(self.recorded_job()['error_code'], 'OUTPUT')
        self.assertFalse(self.recorded_job()['stop_confirmed'])
        self.assertEqual(self.start('other').status_code, 409)
