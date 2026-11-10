import contextlib
import io
import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from test_mailbox_chat import mc, FakeRun, SID, LEFT


class LinuxAgyTests(unittest.TestCase):
    def test_proc(self):
        self.assertTrue(mc.process_argv(os.getpid()))
        self.assertTrue(os.path.isabs(mc.executable_path(os.getpid())))
        self.assertIsNone(mc.process_argv(999999999))
        self.assertIsNone(mc.executable_path(999999999))

    def test_receive_and_cleanup(self):
        message = {'id': 'M1', 'body': '[peer chat] hello'}
        fake = FakeRun(mailboxes={f'{SID}:{LEFT}': [message]})
        with tempfile.TemporaryDirectory() as d, mock.patch.object(mc, 'STATE_DIR', Path(d)), \
             mock.patch.dict(os.environ, AGTERM_SESSION_ID=SID, AGTERM_PANE_ID=LEFT), \
             mock.patch.object(mc, 'find_agy_pid', return_value=os.getpid()), \
             mock.patch.object(mc, 'run', fake), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(mc.agy_wait(), 0)
            self.assertIn('hello', out.getvalue())
            self.assertFalse(os.path.exists(mc.state_path(f'agy-{LEFT}.json')))
            self.assertEqual(mc.read_json(mc.state_path(f'agy-{LEFT}-last-mail.json'))['messages'], [message])
            self.assertFalse(fake.mailboxes[f'{SID}:{LEFT}'])

    def test_failure_cleans_registration(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(mc, 'STATE_DIR', Path(d)), \
             mock.patch.dict(os.environ, AGTERM_SESSION_ID=SID, AGTERM_PANE_ID=LEFT), \
             mock.patch.object(mc, 'find_agy_pid', return_value=os.getpid()), \
             mock.patch.object(mc.time, 'sleep', side_effect=mc.ChatError('stop_loop')), \
             mock.patch.object(mc.Waiter, 'peek', side_effect=mc.ChatError('failed')):
            with self.assertRaises(mc.ChatError):
                mc.agy_wait()
            self.assertFalse(os.path.exists(mc.state_path(f'agy-{LEFT}.json')))

    def test_receiver_rejects_stale_or_wrong_session(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(mc, 'STATE_DIR', Path(d)):
            p = mc.state_path(f'agy-{LEFT}.json')
            mc.write_json(p, {'session': SID, 'pid': os.getpid(), 'agy_pid': os.getpid()})
            self.assertEqual(mc.receiver(SID, LEFT), 'agy')
            self.assertEqual(mc.receiver('other', LEFT), 'none')
            mc.write_json(p, {'session': SID, 'pid': 999999999, 'agy_pid': os.getpid()})
            self.assertEqual(mc.receiver(SID, LEFT), 'none')
            mc.write_json(p, {'session': SID, 'pid': os.getpid(), 'agy_pid': 999999999})
            self.assertEqual(mc.receiver(SID, LEFT), 'none')
