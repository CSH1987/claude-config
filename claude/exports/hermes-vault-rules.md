## Vault(옵시디언 볼트) 연동
- 위치는 `.env`의 `OBSIDIAN_VAULT_PATH`로 설정돼 있음 — `obsidian` 스킬(note-taking/obsidian)이
  이 값을 읽어 filesystem-first로 읽기/검색/생성/추가/편집한다.
- 구조: `10_컨텍스트`(패턴·원칙) / `20_업무위키`(채널운영·시술가격·프로세스·FAQ) /
  `30_결정로그`(날짜별 결정기록) / `90_Hermes`(Hermes 산출물) / `00_홈.md`(볼트 센티널).
- 2026-07-31 사용자 결정으로 전 폴더 자유 읽기/쓰기 허용(승인 절차 없음) — 단 `00_홈.md`는
  가드 자기보호를 위해 `pre_tool_call` 셸훅(`~/.hermes/agent-hooks/protect-vault-sentinel.sh`)이
  예외 없이 차단한다(구조적 안전장치, 다른 경로의 자유쓰기와 무관하게 유지).
- `llm-wiki` 스킬(research/llm-wiki)은 이 볼트와 구조가 달라(SCHEMA.md/index.md/entities 등
  Karpathy 패턴) 이 볼트에 연결하지 않는다 — `WIKI_PATH`는 Vault를 가리키지 않음.
