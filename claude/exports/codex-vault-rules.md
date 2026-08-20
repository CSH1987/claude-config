## Vault(옵시디언 볼트) 연동
- 위치는 `~/.claude/vault-scope.json`의 `vaultPath` 값이다 — 파일시스템으로 직접 읽기/검색/생성/추가/편집한다.
- 구조: `10_컨텍스트`(패턴·원칙, 정본) / `20_업무위키`(채널운영·시술가격·프로세스·FAQ) / `30_결정로그`(날짜별 결정기록) / `90_Hermes`(Hermes 산출물) / `00_홈.md`(볼트 센티널 — 수정 금지).
- 지속 적용될 지침·규칙·선호를 받으면 `10_컨텍스트`에 기록한다 — Claude Code·hermes-agent·codex 공통 착지점(single source of truth).
