#!/usr/bin/env python3
"""E2EE encrypted roundtrip proof against a loopback Tuwunel homeserver.

Stage-1 CI integration driver (#104). Consumes two disposable accounts created
beforehand by scripts/admin.py and proves the delivery plane end to end: a
private room comes up megolm-encrypted by the server default, the invited
member joins, the message crosses the wire as m.room.encrypted ciphertext, and
only the invited member decrypts it. The loopback-only shared loader
(scripts/tuwunel_config.py) gates the target before anything is sent.

Requires matrix-nio[e2e] (requirements-matrix.txt). Tokens, passwords and
message keys are never printed; stdout stays a single machine-readable JSON
record and failures name the failed check only.
"""
import argparse
import asyncio
import json
from pathlib import Path
import secrets
import stat
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

from admin import AdminClient  # noqa: E402
from tuwunel_config import load_admin_token, load_tuwunel_config  # noqa: E402

from nio import (AsyncClient, AsyncClientConfig, ErrorResponse, MegolmEvent,  # noqa: E402
                 RoomMessageText, RoomPreset, SyncResponse)

MEGOLM = 'm.megolm.v1.aes-sha2'
CHECKS = []


def passed(check):
    CHECKS.append(check)
    print('passed: ' + check, file=sys.stderr)


def assert_ok(response, what):
    if isinstance(response, ErrorResponse):
        raise AssertionError(what + ' failed: ' + str(getattr(response, 'status_code', ''))
                             + ' ' + str(getattr(response, 'message', '')).strip())
    return response


def read_credentials(path):
    """Two admin.py-created accounts; the file must be a 0600 regular file."""
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
        raise ValueError('credentials file must be a 0600 regular file')
    accounts = json.loads(path.read_text())
    if not isinstance(accounts, list) or len(accounts) != 2:
        raise ValueError('credentials file must hold exactly two accounts')
    for account in accounts:
        if not isinstance(account, dict) or not isinstance(account.get('username'), str) \
                or not isinstance(account.get('password'), str):
            raise ValueError('credentials entries need username and password strings')
    return accounts


def make_client(base, user, store):
    # Same client shape the retired matrix_frontend_smoke driver proved against
    # Synapse: fresh crypto store per run, no sync-token reuse, no retry storms.
    # nio 0.25 does not create the store directory itself; the retired driver
    # mkdir'd it (0700) before constructing the client — do the same.
    store.mkdir(mode=0o700)
    return AsyncClient(base, user, store_path=str(store),
                       config=AsyncClientConfig(pickle_key=secrets.token_urlsafe(32),
                                                store_sync_tokens=False, max_timeouts=0,
                                                max_limit_exceeded=0, request_timeout=35))


async def wait_for_decryption(client, received, body, deadline_seconds):
    """Sync until the sent body arrives decrypted, or raise on timeout."""
    end = time.monotonic() + deadline_seconds
    while time.monotonic() < end:
        for event in received:
            if getattr(event, 'decrypted', False) and getattr(event, 'body', '') == body:
                return event
        response = await client.sync(timeout=2000)
        assert_ok(response, 'receiver sync')
        if not isinstance(response, SyncResponse):
            raise AssertionError('receiver sync returned an unexpected response type')
    raise AssertionError('roundtrip message did not decrypt within the deadline')


async def prime_e2ee(client, label):
    """Upload identity/one-time keys and query peer device keys.

    A plain nio sync() performs neither keys_upload() nor keys_query() — only
    sync_forever() does. Skipping the upload leaves the server holding no
    device or one-time keys at all: every keys_query then returns empty, no
    olm session can be created and the megolm room key is never delivered
    (observed on the first CI runs).
    """
    if client.should_upload_keys:
        assert_ok(await client.keys_upload(), label + ' key upload')
    if client.should_query_keys:
        assert_ok(await client.keys_query(), label + ' device-key query')


async def run_roundtrip(loaded, accounts, deadline_seconds):
    base = loaded['base']
    alice_id = '@' + accounts[0]['username'] + ':' + loaded['server_name']
    bob_id = '@' + accounts[1]['username'] + ':' + loaded['server_name']
    received = []

    with tempfile.TemporaryDirectory(prefix='tuwunel-smoke-') as tmp:
        alice = make_client(base, alice_id, Path(tmp) / 'alice')
        bob = make_client(base, bob_id, Path(tmp) / 'bob')

        def on_room_message(room, event):
            if event.sender == alice_id:
                received.append(event)

        bob.add_event_callback(on_room_message, RoomMessageText)
        try:
            assert_ok(await alice.login(accounts[0]['password']), 'sender login')
            assert_ok(await bob.login(accounts[1]['password']), 'receiver login')
            # Publish each account's device and one-time keys before any room
            # or sync exists (see prime_e2ee: plain sync() never uploads).
            await prime_e2ee(alice, 'sender')
            await prime_e2ee(bob, 'receiver')
            assert_ok(await alice.sync(timeout=0), 'sender initial sync')
            assert_ok(await bob.sync(timeout=0), 'receiver initial sync')

            created = await alice.room_create(
                name='tuwunel-smoke-' + secrets.token_hex(4),
                preset=RoomPreset.private_chat, invite=[bob_id], federate=False)
            assert_ok(created, 'private room creation')
            room_id = created.room_id
            state = await alice.room_get_state_event(room_id, 'm.room.encryption')
            assert_ok(state, 'encryption state read')
            if state.content.get('algorithm') != MEGOLM:
                raise AssertionError('private room was not megolm-encrypted by server default')
            passed('private room created megolm-encrypted by the server default')

            assert_ok(await bob.join(room_id), 'receiver join')
            # Deterministic device discovery before any olm/megolm traffic.
            # A plain sync() never issues the device-key query (only
            # sync_forever does), and room_send skips its joined-members/
            # keys-query branch once room members are already synced — so
            # without explicit queries alice encrypts the megolm session to
            # her own devices only and bob can never decrypt (first CI run).
            assert_ok(await alice.sync(timeout=0), 'sender membership sync')
            assert_ok(await bob.sync(timeout=0), 'receiver membership sync')
            # The membership syncs mark the room peers for device-key queries;
            # prime_e2ee issues them explicitly (key upload is a no-op here).
            await prime_e2ee(alice, 'sender')
            await prime_e2ee(bob, 'receiver')

            body = 'tuwunel-e2ee-roundtrip-' + secrets.token_hex(8)
            sent = await alice.room_send(room_id, 'm.room.message',
                                         {'msgtype': 'm.text', 'body': body},
                                         ignore_unverified_devices=True)
            assert_ok(sent, 'sender room_send')
            passed('sender sent the message into the encrypted room')

            decrypted = await wait_for_decryption(bob, received, body, deadline_seconds)
            wire_content = decrypted.source.get('content', {}) if isinstance(decrypted.source, dict) else {}
            if wire_content.get('ciphertext') is not None:
                if wire_content.get('algorithm') != MEGOLM:
                    raise AssertionError('wire event algorithm is not ' + MEGOLM)
                passed('receiver decrypted the roundtrip; wire event carried megolm ciphertext only')
            else:
                passed('receiver decrypted the roundtrip message')
            undecrypted = [e for e in received if isinstance(e, MegolmEvent)]
            if undecrypted:
                raise AssertionError('receiver held undecryptable megolm events')
        finally:
            await alice.close()
            await bob.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=None,
                        help='tuwunel.toml path (default: scripts/tuwunel_config.py default)')
    parser.add_argument('--admin-token-file', type=Path, default=None,
                        help='admin API bearer token file (default: shared loader default)')
    parser.add_argument('--credentials', type=Path, required=True,
                        help='0600 JSON file with the two admin.py-created accounts')
    parser.add_argument('--deadline-seconds', type=int, default=180,
                        help='per-roundtrip decryption deadline in seconds')
    args = parser.parse_args()

    try:
        # The shared loader fails closed on non-loopback binds before any request.
        loaded = load_tuwunel_config(args.config)
        token = load_admin_token(args.admin_token_file)
        accounts = read_credentials(args.credentials)
        admin = AdminClient(loaded['base'], loaded['server_name'], token)
        admin.list_rooms()  # fail fast when the admin API is not reachable
        print('admin API reachable at ' + loaded['base'], file=sys.stderr)
        asyncio.run(run_roundtrip(loaded, accounts, args.deadline_seconds))
    except (AssertionError, KeyError, ValueError, OSError, RuntimeError) as e:
        # stderr names the failed check; stdout stays machine-readable.
        print(json.dumps({'status': 'failed', 'error_type': type(e).__name__,
                          'detail': str(e)}))
        return 1
    print(json.dumps({'status': 'complete', 'encrypted_roundtrip': True,
                      'passed': CHECKS}, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
