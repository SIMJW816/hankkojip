"""한 포트에서 제조 명령을 전송하고 Arduino의 상태를 주기적으로 읽습니다."""

import json
import logging
import math
import re
import threading
import time
import uuid


SLOT_IDS = ('P1', 'P2', 'P3', 'P4', 'L1', 'L2')
POWDER_PHASES = ('homing', 'positioning', 'checking', 'engaging', 'disengaging')
DEVICE_PHASES = ('taring', 'dispensing', 'settling', 'stopping') + POWDER_PHASES
DEVICE_RESULTS = ('completed', 'stopped', 'error')
MAX_FRAME = 1536
STATUS_INTERVAL = 0.2
STATUS_TIMEOUT = 0.45
STATUS_MAX_AGE = 1.0
LOGGER = logging.getLogger(__name__)

ERRORS = {
    'LINK_LOST': 'Arduino 응답이 끊겼습니다.',
    'JOB_LOST': 'Arduino에서 이 작업의 결과를 확인할 수 없습니다.',
    'NOT_READY': '장치 준비 상태 또는 재료 상태가 바뀌었습니다.',
    'INVALID_REPORT': 'Arduino 결과가 요청한 배합과 일치하지 않습니다.',
    'BAD_PLAN': 'Arduino가 슬롯이나 목표 중량을 거부했습니다.',
    'CUP': '컵이 없거나 안정된 위치에 있지 않습니다.',
    'SCALE': '로드셀 측정값을 받을 수 없습니다.',
    'MATERIAL': '계량할 재료가 부족합니다.',
    'MATERIAL_SENSOR': '재료 잔량을 확인할 수 없습니다. 잔량 센서와 연결을 확인해 주세요.',
    'HOME': '분말통 이동부의 원점을 찾을 수 없습니다.',
    'POSITION': '분말통의 중앙 이동이 완료되지 않았습니다.',
    'NO_FLOW': '배출 중 무게 증가가 확인되지 않았습니다.',
    'OVERWEIGHT': '장치의 중량 한계를 넘었습니다.',
    'DISPENSE_TIMEOUT': '재료 배출 시간이 초과되었습니다.',
    'UNSTABLE': '무게가 안정되지 않았습니다.',
    'OUT_OF_TOLERANCE': '실측량이 허용 오차를 벗어났습니다.',
    'WATCHDOG': '통신이 끊겨 Arduino가 배출을 정지했습니다.',
    'SESSION_CHANGED': '제어 서버 연결이 바뀌어 배출을 정지했습니다.',
    'CONFIG': 'Arduino의 핀과 보정값을 설정해 주세요.',
    'OUTPUT': '배출기 출력에 오류가 있습니다. 장치의 물리 정지 상태를 확인해 주세요.',
}


def error_message(code):
    return ERRORS.get(code, '장치 상태를 확인해 주세요.')


def valid_weight(value, *, positive=False):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value) and (value > 0 if positive else value >= 0)
    except OverflowError:
        return False


def decode_status(status):
    """UART 입력을 검증하고 필요한 필드만 반환합니다."""
    if (type(status.get('ready')) is not bool or type(status.get('safe')) is not bool
            or not isinstance(status.get('slots'), dict)):
        raise ValueError('잘못된 STATUS 형식')
    limit = status.get('max_total_g')
    if limit is not None and not valid_weight(limit, positive=True):
        raise ValueError('잘못된 총 중량 한계')
    slots = {}
    for slot, info in status['slots'].items():
        if (slot not in SLOT_IDS or not isinstance(info, dict)
                or not valid_weight(info.get('min_g'), positive=True)
                or not valid_weight(info.get('max_g'), positive=True)
                or info['min_g'] > info['max_g'] or 'present' not in info):
            raise ValueError('잘못된 슬롯 상태')
        present = info['present']
        check = info.get('check_at_center', False)
        sensor = info.get('has_level_sensor', True)
        percent = info.get('remaining_pct')
        if ((present is not None and type(present) is not bool) or type(check) is not bool or type(sensor) is not bool
                or (not sensor and (slot not in SLOT_IDS[:4] or present is not None or check or percent is not None))
                or (check and (slot not in SLOT_IDS[:4] or present is not None))
                or (percent is not None and (type(percent) is not int or not 0 <= percent <= 100
                                             or (present is None and not check)))):
            raise ValueError('잘못된 잔량 센서 상태')
        slots[slot] = dict(min_g=info['min_g'], max_g=info['max_g'], present=present,
                           check_at_center=check, has_level_sensor=sensor, remaining_pct=percent)

    job = status.get('job')
    if job is not None:
        if (not isinstance(job, dict) or not isinstance(job.get('id'), str)
                or re.fullmatch(r'[0-9a-f]{32}', job['id']) is None
                or job.get('phase') not in DEVICE_PHASES + DEVICE_RESULTS
                or not isinstance(job.get('items'), list) or len(job['items']) > len(SLOT_IDS)):
            raise ValueError('잘못된 장치 작업 상태')
        items, seen = [], set()
        for item in job['items']:
            if (not isinstance(item, dict) or item.get('slot') not in SLOT_IDS
                    or item['slot'] in seen or not valid_weight(item.get('target_g'), positive=True)
                    or type(item.get('done')) is not bool
                    or (item.get('actual_g') is not None and not valid_weight(item['actual_g']))
                    or (item['done'] and item.get('actual_g') is None)):
                raise ValueError('잘못된 계량 결과')
            seen.add(item['slot'])
            items.append(dict(slot=item['slot'], target_g=item['target_g'],
                              actual_g=item.get('actual_g'), done=item['done']))
        current = job.get('current_slot')
        live = job.get('live_g')
        if ((current is not None and (not isinstance(current, str) or current not in seen))
                or (live is not None and (current is None or not valid_weight(live)))
                or (job['phase'] in POWDER_PHASES and current not in SLOT_IDS[:4])
                or (job['phase'] == 'completed' and (not items or not all(i['done'] for i in items)))
                or (job['phase'] in DEVICE_PHASES and not items)):
            raise ValueError('잘못된 작업 진행 상태')
        code = job.get('error_code')
        job = dict(id=job['id'], phase=job['phase'], items=items, current_slot=current, live_g=live,
                   error_code=(code if code in ERRORS else 'UNKNOWN') if isinstance(code, str) else None)
    active = job is not None and job['phase'] in DEVICE_PHASES
    if ((active and status['safe']) or (not active and not status['safe'] and status.get('error_code') != 'OUTPUT')
            or (status['ready'] and (not status['safe'] or not slots or limit is None))):
        raise ValueError('장치의 준비/정지 상태가 작업 상태와 다릅니다.')
    code = status.get('error_code')
    return dict(ready=status['ready'], safe=status['safe'], max_total_g=limit,
                slots=slots, job=job, error_code=code if isinstance(code, str) and code in ERRORS else None)


class UartLink:
    """GET_STATUS로 결과를 회수합니다. START는 재전송하지 않습니다."""

    def __init__(self, port, baud, report, opener=None):
        if opener is None:
            import serial

            def opener():
                return serial.Serial(port, baud, timeout=0.03, write_timeout=0.2, exclusive=True)

        self.open_port = opener
        self.report = report
        self.session = uuid.uuid4().hex
        self.seq = 0
        self.last_status = 0
        self.halt = threading.Event()
        self.thread = threading.Thread(target=self._run, name='arduino-uart', daemon=True)

    def start(self):
        self.thread.start()

    def close(self):
        self.halt.set()
        self.thread.join(timeout=2)

    def _write(self, port, command):
        self.seq += 1
        frame = dict(command, v=1, session=self.session, seq=self.seq)
        data = json.dumps(frame, allow_nan=False, separators=(',', ':')).encode('ascii') + b'\n'
        if len(data) - 1 > MAX_FRAME or port.write(data) != len(data):
            raise OSError('UART 프레임을 모두 보내지 못했습니다.')

    def _status(self, port):
        self._write(port, dict(command='GET_STATUS', ack=self.last_status))
        deadline = time.monotonic() + STATUS_TIMEOUT
        line = bytearray()
        overflow = False
        while not self.halt.is_set() and time.monotonic() < deadline:
            for byte in port.read(min(256, port.in_waiting or 1)):
                if byte != 10:
                    if len(line) < MAX_FRAME:
                        line.append(byte)
                    else:
                        overflow = True
                    continue
                packet = None
                if line and not overflow:
                    try:
                        packet = json.loads(line)
                    except (ValueError, RecursionError):
                        pass
                line.clear()
                overflow = False
                if (isinstance(packet, dict) and packet.get('event') == 'STATUS'
                        and packet.get('session') == self.session and type(packet.get('seq')) is int
                        and packet['seq'] == self.seq):
                    if type(packet.get('v')) is not int or packet['v'] != 1:
                        raise ValueError('지원하지 않는 UART 프로토콜')
                    status = decode_status(packet)
                    self.last_status = self.seq
                    return status
        raise TimeoutError('UART 상태 응답 시간 초과')

    def _run(self):
        failure = None
        while not self.halt.is_set():
            try:
                with self.open_port() as port:
                    while not self.halt.is_set():
                        status = self._status(port)
                        failure = None
                        command = self.report(status)
                        if command and not self.halt.is_set():
                            self._write(port, dict(command, ack=self.last_status))
                        self.halt.wait(STATUS_INTERVAL)
            except (OSError, ValueError) as exc:
                if self.halt.is_set():
                    break
                if str(exc) != failure:
                    failure = str(exc)
                    LOGGER.warning('Arduino UART 응답 실패: %s', failure)
                self.report(None)
                self.halt.wait(0.5)
            except Exception:
                # Heartbeat를 멈춰 보드가 자체 정지하도록 하고 오류를 기록합니다.
                LOGGER.exception('Arduino UART 작업 스레드가 중단되었습니다.')
                self.report(None)
                return
