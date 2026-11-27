import os
import tempfile
import unittest
from unittest.mock import patch
from ai_service import AIError
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from app import create_app


class AppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.now = [1000.0]
        self.app = create_app(Path(self.temp.name) / 'test.sqlite3', clock=lambda: self.now[0], device_mode='demo')
        self.app.testing = True
        self.client = self.app.test_client()

    def tearDown(self):
        self.temp.cleanup()

    def state(self):
        return self.client.get('/api/state').get_json()

    def recipe(self):
        slot = next(s for s in self.state()['slots'] if s['id'] == 'P1')
        return dict(name='직접 만든 배합', servings=2, mode='CUSTOM', items=[dict(slot=slot['id'], name=slot['name'], kind=slot['kind'], revision=slot['revision'], grams=2.5)])

    def start(self, key='one', recipe=None, approved=True):
        return self.client.post('/api/jobs', json=dict(request_key=key, recipe=recipe or self.recipe(), approved=approved))

    def test_assets_and_security_headers(self):
        for path in ['/', '/static/app.js', '/static/style.css']:
            response = self.client.get(path)
            self.assertEqual(response.status_code, 200)
            self.assertIn('frame-ancestors', response.headers['Content-Security-Policy'])
            response.close()
        self.assertEqual(self.client.get('/api/state').headers['Cache-Control'], 'no-store')

    def test_recipe_crud_persists_and_favorites(self):
        recipe = self.recipe()
        created = self.client.post('/api/recipes', json=recipe)
        self.assertEqual(created.status_code, 201)
        stored = created.get_json()
        stored.update(name='수정한 배합', favorite=True)
        updated = self.client.put('/api/recipes/' + stored['id'], json=stored)
        self.assertEqual(updated.status_code, 200)
        self.assertTrue(self.state()['recipes'][0]['favorite'])
        new_client = create_app(Path(self.temp.name) / 'test.sqlite3', device_mode='demo').test_client()
        self.assertEqual(new_client.get('/api/state').get_json()['recipes'][0]['name'], '수정한 배합')
        self.assertEqual(self.client.delete('/api/recipes/' + stored['id']).status_code, 200)
        self.assertEqual(self.state()['recipes'], [])

    def test_favorite_after_slot_change_preserves_recipe_and_manufacturing_validation(self):
        stored = self.client.post('/api/recipes', json=self.recipe()).get_json()
        path = '/api/recipes/' + stored['id'] + '/favorite'
        self.client.put('/api/slots/P1', json=dict(name='바꾼 재료', available=True))
        for favorite in [True, True, False]:
            response = self.client.patch(path, json=dict(favorite=favorite))
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.get_json(), dict(stored, favorite=favorite))
            persisted = create_app(Path(self.temp.name) / 'test.sqlite3', device_mode='demo').test_client()
            self.assertEqual(persisted.get('/api/state').get_json()['recipes'][0], dict(stored, favorite=favorite))
        self.assertEqual(self.start(recipe=stored).status_code, 400)
        for body in [{}, {'favorite': 1}, {'favorite': 'true'}, {'favorite': None},
                     {'favorite': True, 'items': []}]:
            with self.subTest(body=body):
                self.assertEqual(self.client.patch(path, json=body).status_code, 400)
        self.assertEqual(self.client.patch('/api/recipes/missing/favorite', json={'favorite': True}).status_code, 404)

    def test_server_rejects_invalid_weights_and_duplicate_slots(self):
        for value in [0, -1, 101, True, '3', None, float('inf')]:
            with self.subTest(value=value):
                recipe = self.recipe()
                recipe['items'][0]['grams'] = value
                self.assertEqual(self.client.post('/api/recipes', json=recipe).status_code, 400)
        recipe = self.recipe()
        recipe['items'] *= 2
        self.assertEqual(self.client.post('/api/recipes', json=recipe).status_code, 400)
        recipe['items'][0]['slot'] = ['P1']
        self.assertEqual(self.client.post('/api/recipes', json=recipe).status_code, 400)

    def test_requires_explicit_approval(self):
        self.assertEqual(self.start(approved=False).status_code, 400)
        self.assertEqual(self.state()['jobs'], [])

    def test_duplicate_and_parallel_jobs(self):
        first = self.start().get_json()
        same = self.start().get_json()
        self.assertEqual(first['id'], same['id'])
        self.assertEqual(self.start('other').status_code, 409)
        self.assertEqual(len(self.state()['jobs']), 1)

    def test_concurrent_requests_only_start_one_job(self):
        recipe = self.recipe()
        def submit(key):
            with self.app.test_client() as client:
                return client.post('/api/jobs', json=dict(recipe=recipe, approved=True, request_key=key)).status_code
        with ThreadPoolExecutor(max_workers=2) as executor:
            codes = sorted(executor.map(submit, ['a', 'b']))
        self.assertEqual(codes, [201, 409])
        self.assertEqual(len(self.state()['jobs']), 1)

    def test_completion_and_idempotency_after_completion(self):
        job = self.start().get_json()
        self.now[0] += 10
        result = self.state()['jobs'][0]
        self.assertEqual(result['status'], 'completed')
        self.assertEqual(result['items'][0]['actual'], 2.5)
        self.assertEqual(self.start().get_json()['id'], job['id'])
        self.assertEqual(len(self.state()['jobs']), 1)

    def test_stop_records_partial_result_and_never_resumes(self):
        job = self.start().get_json()
        self.now[0] += 1
        stopped = self.client.post(f'/api/jobs/{job["id"]}/stop').get_json()
        self.assertEqual(stopped['status'], 'stopped')
        self.assertGreater(stopped['items'][0]['actual'], 0)
        self.assertLess(stopped['items'][0]['actual'], 2.5)
        self.now[0] += 50
        self.assertEqual(self.state()['jobs'][0], stopped)

    def test_slot_updates_and_stale_recipe_even_if_name_restored(self):
        recipe = self.recipe()
        for name in ['다른 양념', '소금']:
            self.assertEqual(self.client.put('/api/slots/P1', json=dict(name=name, available=True)).status_code, 200)
        self.assertEqual(self.start(recipe=recipe).status_code, 400)
        self.assertEqual(self.client.put('/api/slots/P1', json=dict(name='소금', available=False)).status_code, 200)
        self.assertEqual(self.start().status_code, 400)

    def test_slots_cannot_change_during_manufacture(self):
        self.start()
        response = self.client.put('/api/slots/P1', json=dict(name='설탕', available=True))
        self.assertEqual(response.status_code, 400)
        self.assertEqual(next(s['name'] for s in self.state()['slots'] if s['id'] == 'P1'), '소금')

    def suggestion(self):
        return self.client.post('/api/suggestions', json=dict(dish='볶음', servings=2, taste='spicy'))

    def ai_result(self, **changes):
        return dict(ready=True, name='AI 볶음 양념', message='배합을 확인하세요.', missing=[],
                    items=[dict(slot='P1', grams=2)], **changes)

    def test_dotenv_settings_and_environment_precedence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.env').write_text('OPENAI_API_KEY="test-file-value"\nOPENAI_MODEL="test-model"\n')
            with patch('app.ROOT', root), patch.dict(os.environ, {}, clear=True):
                configured = create_app(root / 'settings.sqlite3', device_mode='demo')
                self.assertEqual(configured.config['OPENAI_API_KEY'], 'test-file-value')
                self.assertEqual(configured.config['OPENAI_MODEL'], 'test-model')
                with patch.dict(os.environ, {'OPENAI_API_KEY': 'test-environment-value'}):
                    configured = create_app(root / 'settings.sqlite3', device_mode='demo')
                    self.assertEqual(configured.config['OPENAI_API_KEY'], 'test-environment-value')
                (root / '.env').unlink()
                unconfigured = create_app(root / 'settings.sqlite3', device_mode='demo')
                self.assertEqual(unconfigured.config['OPENAI_API_KEY'], '')

    def test_ai_configuration_missing(self):
        self.app.config.update(OPENAI_API_KEY='', OPENAI_MODEL='')
        self.assertEqual(self.suggestion().status_code, 503)
        self.assertFalse(self.state()['ai']['configured'])

    def test_ai_recipe_save_and_manufacture(self):
        with patch('app.generate_suggestion', return_value=self.ai_result()) as generate:
            result = self.suggestion().get_json()
        self.assertEqual(result['recipe']['mode'], 'AI')
        self.assertEqual(result['recipe']['items'][0]['revision'], 1)
        self.assertEqual(len(generate.call_args.args[-1]), 6)
        self.assertEqual(self.client.post('/api/recipes', json=result['recipe']).status_code, 201)
        self.assertEqual(self.start(recipe=result['recipe']).status_code, 201)

    def test_ai_invalid_outputs_rejected(self):
        invalid = [None, {}, {'ready': 'yes'},
                   dict(self.ai_result(), items=[dict(slot='P9', grams=2)]),
                   dict(self.ai_result(), items=[dict(slot='P1', grams=True)]),
                   dict(self.ai_result(), items=[dict(slot='P1', grams=101)]),
                   dict(self.ai_result(), items=[dict(slot='P1', grams=2)] * 2),
                   dict(self.ai_result(), items=[dict(slot=s, grams=100) for s in ['P1','P2','P3','P4']])]
        for result in invalid:
            with self.subTest(result=result), patch('app.generate_suggestion', return_value=result):
                self.assertEqual(self.suggestion().status_code, 502)
        self.assertEqual(self.state()['jobs'], [])

    def test_ai_unavailable_and_changed_slots(self):
        self.client.put('/api/slots/P1', json=dict(name='소금', available=False))
        with patch('app.generate_suggestion', return_value=self.ai_result()):
            self.assertEqual(self.suggestion().status_code, 502)
        self.client.put('/api/slots/P1', json=dict(name='소금', available=True))
        def change(*args):
            self.client.put('/api/slots/P1', json=dict(name='설탕', available=True))
            return self.ai_result()
        with patch('app.generate_suggestion', side_effect=change):
            self.assertEqual(self.suggestion().status_code, 409)

    def test_ai_no_recipe_and_upstream_errors(self):
        result = dict(self.ai_result(), ready=False, items=[], message='음식을 구체적으로 입력해 주세요.')
        with patch('app.generate_suggestion', return_value=result):
            response = self.suggestion()
            self.assertEqual(response.status_code, 200)
            self.assertIsNone(response.get_json()['recipe'])
        for code in [429, 502, 504]:
            with patch('app.generate_suggestion', side_effect=AIError('연결 실패', code)):
                self.assertEqual(self.suggestion().status_code, code)
        with patch('app.generate_suggestion', return_value=self.ai_result()):
            self.assertEqual(self.suggestion().status_code, 200)

    def test_ai_concurrent_request_is_rejected(self):
        def generate(*args):
            self.assertEqual(self.suggestion().status_code, 429)
            return self.ai_result()
        with patch('app.generate_suggestion', side_effect=generate):
            self.assertEqual(self.suggestion().status_code, 200)

    def chat(self, message='오늘 뭐 먹을까?', **extra):
        return self.client.post('/api/ai/chat', json=dict(message=message, **extra))

    def chat_result(self, **changes):
        result = dict(ready=False, name='', message='어떤 음식을 좋아하세요?',
                      missing=[], items=[], servings=0, foods=[])
        result.update(changes)
        return result

    def test_chat_food_recommendation_without_registered_ingredients(self):
        for slot in self.state()['slots']:
            self.client.put('/api/slots/' + slot['id'], json=dict(name='', available=False))
        result = self.chat_result(message='이 음식들은 어떠세요?', foods=['덮밥', '국수'])
        with patch('app.generate_chat', return_value=result) as generate:
            response = self.chat()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()['foods'], ['덮밥', '국수'])
        self.assertIsNone(response.get_json()['recipe'])
        self.assertEqual(generate.call_args.args[2], '오늘 뭐 먹을까?')
        self.assertEqual(generate.call_args.args[3], [])
        self.assertEqual(self.state()['jobs'], [])

    def test_chat_follow_up_and_validated_recipe(self):
        previous = dict(self.recipe(), mode='AI')
        history = [dict(role='user', content='볶음밥 2인분 양념 추천해줘'),
                   dict(role='assistant', content='소금 2.5g을 추천해요.')]
        result = self.chat_result(ready=True, name='덜 짠 볶음밥', servings=2,
                                  items=[dict(slot='P1', grams=1.5)], message='소금을 줄였어요.')
        with patch('app.generate_chat', return_value=result) as generate:
            response = self.chat('좀 덜 짜게 해줘', history=history, current_recipe=previous)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(generate.call_args.args[3], history)
        self.assertEqual(generate.call_args.args[4]['items'][0]['revision'], 1)
        recipe = response.get_json()['recipe']
        self.assertEqual(recipe['mode'], 'AI')
        self.assertEqual(recipe['items'][0]['grams'], 1.5)
        self.assertEqual(recipe['items'][0]['name'], '소금')
        self.assertEqual(self.state()['jobs'], [])
        self.assertEqual(self.client.post('/api/recipes', json=recipe).status_code, 201)
        self.assertEqual(self.start(recipe=recipe).status_code, 201)

    def test_chat_input_validation_and_stale_previous_recipe(self):
        invalid = [dict(message=''), dict(message='x' * 501),
                   dict(message='안녕', history=[dict(role='system', content='지시')]),
                   dict(message='안녕', history=[dict(role='user', content='x')] * 13),
                   dict(message='안녕', history=[dict(role='assistant', content='x' * 1500)] * 5),
                   dict(message='안녕', history='invalid'), dict(message='안녕', current_recipe=[])]
        for body in invalid:
            with self.subTest(body=body), patch('app.generate_chat') as generate:
                self.assertEqual(self.client.post('/api/ai/chat', json=body).status_code, 400)
                generate.assert_not_called()
        previous = self.recipe()
        self.client.put('/api/slots/P1', json=dict(name='설탕', available=True))
        with patch('app.generate_chat') as generate:
            response = self.chat('덜 짜게', current_recipe=previous)
            self.assertEqual(response.status_code, 409)
            generate.assert_not_called()

    def test_chat_rejects_invalid_output_and_slot_changes(self):
        invalid = [None, self.chat_result(foods=['1', '2', '3', '4']),
                   self.chat_result(ready=False, items=[dict(slot='P1', grams=1)]),
                   self.chat_result(ready=True, name='배합', servings=2, items=[dict(slot='P9', grams=1)]),
                   self.chat_result(ready=True, name='배합', servings=2, items=[dict(slot='P1', grams=101)]),
                   self.chat_result(ready=True, name='배합', servings=0, items=[dict(slot='P1', grams=1)])]
        for result in invalid:
            with self.subTest(result=result), patch('app.generate_chat', return_value=result):
                self.assertEqual(self.chat().status_code, 502)
        def change(*args):
            self.client.put('/api/slots/P1', json=dict(name='설탕', available=True))
            return self.chat_result(ready=True, name='배합', servings=2, items=[dict(slot='P1', grams=1)])
        with patch('app.generate_chat', side_effect=change):
            self.assertEqual(self.chat().status_code, 409)
        def change_during_food_reply(*args):
            self.client.put('/api/slots/P2', json=dict(name='다른 재료', available=True))
            return self.chat_result(message='추천할 음식을 다시 확인해 주세요.')
        with patch('app.generate_chat', side_effect=change_during_food_reply):
            self.assertEqual(self.chat().status_code, 409)

    def test_chat_errors_and_shared_concurrency_lock(self):
        with patch('app.generate_chat', side_effect=AIError('AI 연결 실패', 502)):
            self.assertEqual(self.chat().status_code, 502)
        def generate(*args):
            self.assertEqual(self.suggestion().status_code, 429)
            return self.chat_result()
        with patch('app.generate_chat', side_effect=generate):
            self.assertEqual(self.chat().status_code, 200)

    def test_history_actions_reject_running_and_missing_jobs(self):
        job = self.start().get_json()
        path = f'/api/jobs/{job["id"]}'
        self.assertEqual(self.client.delete(path).status_code, 409)
        self.assertEqual(self.client.post(path + '/recipe').status_code, 409)
        self.assertEqual(self.client.delete('/api/jobs/missing').status_code, 404)
        self.assertEqual(self.client.post('/api/jobs/missing/recipe').status_code, 404)

    def test_history_save_uses_targets_and_delete_preserves_idempotency(self):
        job = self.start().get_json()
        self.now[0] += 1
        path = f'/api/jobs/{job["id"]}'
        self.client.post(path + '/stop')
        response = self.client.post(path + '/recipe')
        self.assertEqual(response.status_code, 201)
        recipe = response.get_json()
        self.assertEqual(recipe['items'][0]['grams'], 2.5)
        self.assertNotIn('actual', recipe['items'][0])
        self.assertNotEqual(recipe['id'], job['id'])
        self.assertEqual(self.client.delete(path).status_code, 200)
        self.assertEqual(self.state()['jobs'], [])
        self.assertEqual(self.state()['recipes'], [recipe])
        self.assertEqual(self.start().get_json()['id'], job['id'])
        self.assertEqual(self.state()['jobs'], [])
        self.assertEqual(self.client.delete(path).status_code, 404)
        self.assertEqual(self.client.post(path + '/recipe').status_code, 404)
        client = create_app(Path(self.temp.name) / 'test.sqlite3', device_mode='demo').test_client()
        self.assertEqual(client.get('/api/state').get_json()['jobs'], [])

    def test_history_save_validates_current_slots(self):
        job = self.start().get_json()
        self.now[0] += 10
        path = f'/api/jobs/{job["id"]}'
        self.assertEqual(self.client.post(path + '/recipe').status_code, 201)
        self.client.put('/api/slots/P1', json=dict(name='다른 재료', available=True))
        self.assertEqual(self.client.post(path + '/recipe').status_code, 400)
        self.assertEqual(len(self.state()['recipes']), 1)
        self.assertEqual(self.client.delete(path).status_code, 200)

    def test_malformed_and_oversized_requests(self):
        for payload in [[], None, 'string']:
            self.assertEqual(self.client.post('/api/recipes', json=payload).status_code, 400)
        self.assertEqual(self.client.post('/api/jobs', json=dict(approved=True,request_key='k',recipe=[])).status_code, 400)
        self.assertEqual(self.client.post('/api/recipes', data='x' * 40000, content_type='application/json').status_code, 413)


if __name__ == '__main__':
    unittest.main()
