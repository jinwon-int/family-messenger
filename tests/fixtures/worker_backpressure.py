"""Actual stdio entrypoint, synthetic runtime, no credentials or network."""
import asyncio
from pathlib import Path
import sys
import types
from types import SimpleNamespace as N

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
from fleet_worker import main


class Runtime:
    session_id='synthetic'
    def __init__(self,**kwargs):pass
    async def start_or_resume(self,request):return self
    async def send_turn(self,*args,**kwargs):
        yield N(kind='text_delta',text='\x01'*65_536)
        yield N(kind='completion',stop_reason='end_turn')
    async def interrupt(self):pass
    async def close(self):pass


contract=types.ModuleType('telegram_bot.core.agent_runtime')
contract.ApprovalDecision=N(ALLOW='allow',DENY='deny')
contract.SessionRequest=lambda **kwargs:kwargs
adapter=types.ModuleType('telegram_bot.core.codex_runtime')
adapter.CodexRuntime=Runtime
sys.modules['telegram_bot.core.agent_runtime']=contract
sys.modules['telegram_bot.core.codex_runtime']=adapter
try:
    asyncio.run(main(N(workdir=str(Path(__file__).parent),codex_cli=sys.executable,turn_timeout=.05)))
except Exception:
    sys.exit(1)
