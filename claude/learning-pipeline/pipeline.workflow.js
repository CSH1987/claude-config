export const meta = {
  name: 'vault-learning-pipeline',
  description: 'Claude Code(+Hermes) 대화에서 패턴을 뽑아 Vault 10_컨텍스트를 갱신 (hermes-agent 전달은 hermes-sync.sh의 vault-context 블록이 담당 — 2026-08-19 SOOHA_CONTEXT 레그 제거). 2026-08-19 Phase 1: 외부 사례(mem0/Graphiti) 기반 절대시간 고정 + 기존항목 재확인 카운트 + confidence×harm 반영기준 추가. Phase 2: Graphiti/mem0식 비파괴적 반영(삭제 대신 "폐기됨" 표시 후 신규 추가). Phase 3: Letta식 리플렉션 게이트 — 세션 내 자기정정 감지 후 렌즈에 전달(실패해도 파이프라인은 계속). Phase 4: Letta 스킬 파일식 감사 기록 — 매 실행분을 90_Hermes/학습이력/에 별도 파일로 먼저 남긴 뒤 캐노니컬 노트에 반영(vault90HermesPath 없으면 건너뜀). Phase 5(토큰최적화): 리플렉션+렌즈 3개 프롬프트가 전부 "다음 사용자 발화 데이터셋을 읽어라" 문장으로 동일하게 시작하도록 재배치 — Anthropic 공식 팬아웃 캐시공유 조건(동일 프리픽스) 충족 목적, 정보 내용은 불변 — 상세는 Vault 90_Hermes/보고서/2026-08-19_학습파이프라인-외부사례기반-고도화기획.md. Phase 6(2026-08-19, 자가고도화 루프 딥인터뷰): 종합단계 요약 맨 앞줄에 "재확인 N / 신규 M" 집계를 추가 — 실시간 패턴 기록(대화 중 즉시 반영)이 이번 주 무엇을 놓쳤는지 사후 감사하는 역할. 새 렌즈·새 LLM 호출 없이 기존 hasUpdate/summary만으로 집계(비용 불변). Phase 7(2026-08-20, 3티어 워크포스 성장형 루프 — workload-optimization §5.10): `lens:routing` 추가 — ccusage 지출·model-relay/metrics.jsonl 반려율·역할×실효모델 적합성을 집계해 라우팅 개선 제안을 만든다. 다른 렌즈와 달리 Vault 캐노니컬 문서를 직접 고치지 않고 90_Hermes/라우팅제안/ 아래 드래프트 파일로만 남긴다(vault90HermesPath 없으면 건너뜀) — claude-config 동작(SKILL.md 티어맵) 변경은 사람 승인 게이트를 거쳐야 하므로(CLAUDE.md 2026-08-19), synthesis 단계의 자동 Edit 대상에서 의도적으로 제외한다.',
  phases: [
    { title: '리플렉션' },
    { title: '추출' },
    { title: '종합/반영', model: 'opus' },
  ],
}

// 전부 args로 받는다(머신·계정마다 경로가 다름 — 하드코딩 금지, Node API 접근도 없어서 process.env도 못 씀).
// run.sh가 실행 시점에 $HOME 기준 실제 경로를 채워서 넘긴다. args 누락 시 명확히 실패시킨다(잘못된 경로로 조용히 진행 금지).
if (!args || !args.vault10Path || !args.utterancesPath) {
  throw new Error('args.vault10Path / utterancesPath 가 전부 필요합니다 — run.sh에서 채워 넘겨야 함')
}
const VAULT = args.vault10Path
const UTTERANCES_PATH = args.utterancesPath
const MEMORY_DIR = args.memoryDirPath || ''
const VAULT_90_HERMES = args.vault90HermesPath || '' // 없으면(구버전 run.sh 등) Phase 4 감사 기록만 건너뜀 — 핵심 기능엔 영향 없음

const LENSES = [
  {
    key: 'ai-collab',
    file: `${VAULT}/AI_협업_패턴.md`,
    prompt: `다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
이 파일도 읽어라: ${VAULT}/AI_협업_패턴.md (기존 캐노니컬 문서 — 활동 프로파일/지시스타일/교정루프/세션운용/표기체계 섹션 구조).
건수·세션수·기간은 파일 안에서 직접 확인해라(이 프롬프트에 미리 적힌 숫자는 없다 — 매 실행마다 실제 파일 크기가 다르다). 표본이 작으면(수십 건 미만 등) 그 사실 자체를 근거 판단에 반영해라.
각 발화의 ts(원본 타임스탬프)를 절대 날짜 기준으로 삼아라 — suggestedAddition에 "최근"·"요즘"·"얼마 전" 같은 상대시간 표현 대신 실제 날짜(YYYY-MM-DD)를 못박아 써라(이 문서는 계속 남아 나중에 읽히므로 "최근"은 시간이 지나면 의미를 잃는다).
새로운 패턴뿐 아니라, 기존 문서에 이미 있는 항목을 다시 뒷받침하는 근거를 발견했다면 그것도 보고해라 — 이 경우에도 hasUpdate는 true로 표시하고, summary 맨 앞에 "[재확인]"을 붙이고 reasoning에 "기존 항목 재확인"이라고 명시해라(새 패턴 발견과 기존 판단 재확인을 구분해서 알려달라).
반대로 이 제안이 기존 문서의 특정 문장·판단과 내용상 배치되거나(모순되거나 낡아서 대체해야 함) 그것을 대체한다면, supersedes 필드에 그 기존 문장을 원문 그대로 인용해라 — 대부분의 제안은 supersedes가 빈 문자열이어야 정상이다(단순히 "관련 있다"는 정도로는 채우지 마라, 실제로 내용이 배치될 때만). 재확인과 대체는 서로 다른 경우다 — 같은 문장을 이번에 [재확인]하면서 동시에 supersedes에도 인용하지 마라(한 항목에 대해 둘 중 하나만 해당해야 한다).
이 데이터에서 기존 문서의 각 섹션에 추가하거나 갱신할 만한 새로운 패턴이 있는지 분석하라 — 없으면 없다고 정직하게 답하라(표본이 작으면 새 패턴이 없는 게 정상일 수 있다). 억지로 만들어내지 마라.
기존 문서를 직접 고치지 마라 — 이 단계는 제안만 한다.`,
  },
  {
    key: 'principles',
    file: `${VAULT}/업무_원칙_방법론.md`,
    prompt: `다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
이 파일도 읽어라: ${VAULT}/업무_원칙_방법론.md (검증된 판단 규칙만 수록하는 캐노니컬 문서).
건수·세션수·기간은 파일 안에서 직접 확인해라(이 프롬프트에 미리 적힌 숫자는 없다 — 매 실행마다 실제 파일 크기가 다르다).
각 발화의 ts(원본 타임스탬프)를 절대 날짜 기준으로 삼아라 — suggestedAddition에 "최근"·"요즘"·"얼마 전" 같은 상대시간 표현 대신 실제 날짜(YYYY-MM-DD)를 못박아 써라(이 문서는 계속 남아 나중에 읽히므로 "최근"은 시간이 지나면 의미를 잃는다).
새로운 규칙뿐 아니라, 기존 문서에 이미 있는 원칙을 다시 뒷받침하는 근거를 발견했다면 그것도 보고해라 — 이 경우에도 hasUpdate는 true로 표시하고, summary 맨 앞에 "[재확인]"을 붙이고 reasoning에 "기존 항목 재확인"이라고 명시해라(새 규칙 발견과 기존 판단 재확인을 구분해서 알려달라).
반대로 이 제안이 기존 문서의 특정 원칙과 내용상 배치되거나(모순되거나 낡아서 대체해야 함) 그것을 대체한다면, supersedes 필드에 그 기존 문장을 원문 그대로 인용해라 — 대부분의 제안은 supersedes가 빈 문자열이어야 정상이다(단순히 "관련 있다"는 정도로는 채우지 마라, 실제로 내용이 배치될 때만). 재확인과 대체는 서로 다른 경우다 — 같은 문장을 이번에 [재확인]하면서 동시에 supersedes에도 인용하지 마라(한 항목에 대해 둘 중 하나만 해당해야 한다).
이 데이터에서 새로 검증된 업무 판단 규칙(반복 적용 가능한 원칙)이 있는지 분석하라 — 없으면 없다고 정직하게 답하라. 1회성 프로젝트 상태 정보(예: "베가스 CRM 확인해줘" 같은 단발 지시)는 원칙이 아니므로 제외하라.${MEMORY_DIR ? ` 사용자 auto-memory(${MEMORY_DIR})에 이미 같은 취지로 기록된 항목이 있는지도 확인해서 교차검증에 활용해라.` : ''}
기존 문서를 직접 고치지 마라 — 이 단계는 제안만 한다.`,
  },
  {
    key: 'strengths-weaknesses',
    file: `${VAULT}/강점_약점_보완.md`,
    prompt: `다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
이 파일도 읽어라: ${VAULT}/강점_약점_보완.md (자기분석 + 보완장치 캐노니컬 문서).
건수·세션수·기간은 파일 안에서 직접 확인해라(이 프롬프트에 미리 적힌 숫자는 없다 — 매 실행마다 실제 파일 크기가 다르다). 표본이 작으면 그 사실 자체를 근거 판단에 반영해라.
각 발화의 ts(원본 타임스탬프)를 절대 날짜 기준으로 삼아라 — suggestedAddition에 "최근"·"요즘"·"얼마 전" 같은 상대시간 표현 대신 실제 날짜(YYYY-MM-DD)를 못박아 써라(이 문서는 계속 남아 나중에 읽히므로 "최근"은 시간이 지나면 의미를 잃는다).
새로운 관찰뿐 아니라, 기존 문서에 이미 있는 강점/약점/보완장치를 다시 뒷받침하는 근거를 발견했다면 그것도 보고해라 — 이 경우에도 hasUpdate는 true로 표시하고, summary 맨 앞에 "[재확인]"을 붙이고 reasoning에 "기존 항목 재확인"이라고 명시해라(새 관찰과 기존 판단 재확인을 구분해서 알려달라).
반대로 이 제안이 기존 문서의 특정 강점/약점/보완장치 서술과 내용상 배치되거나(모순되거나 낡아서 대체해야 함) 그것을 대체한다면, supersedes 필드에 그 기존 문장을 원문 그대로 인용해라 — 대부분의 제안은 supersedes가 빈 문자열이어야 정상이다(단순히 "관련 있다"는 정도로는 채우지 마라, 실제로 내용이 배치될 때만). 재확인과 대체는 서로 다른 경우다 — 같은 문장을 이번에 [재확인]하면서 동시에 supersedes에도 인용하지 마라(한 항목에 대해 둘 중 하나만 해당해야 한다).
이 데이터에서 기존에 기록된 강점/약점/보완장치와 관련해 새로 확인되거나 갱신할 만한 근거가 있는지 분석하라 — 없으면 없다고 정직하게 답하라.
기존 문서를 직접 고치지 마라 — 이 단계는 제안만 한다.`,
  },
]

const LENS_SCHEMA = {
  type: 'object',
  properties: {
    hasUpdate: { type: 'boolean', description: '새 패턴 제안이 있거나, 기존 항목을 재확인하는 근거를 찾았으면 true(재확인만 있고 새 내용이 없어도 true)' },
    summary: { type: 'string', description: '변경 제안 요약, 없으면 빈 문자열' },
    suggestedAddition: { type: 'string', description: '문서에 추가/수정할 구체 문구(마크다운), 없으면 빈 문자열' },
    reasoning: { type: 'string', description: '근거가 된 발화/패턴 설명' },
    supersedes: { type: 'string', description: '이 제안이 기존 문서의 특정 문장/항목과 내용상 배치되거나 그것을 대체한다면 그 기존 문장을 원문 그대로 인용. 그런 경우가 아니면(대부분) 빈 문자열' },
    basedOnReflection: { type: 'boolean', description: '이 제안이 리플렉션 힌트(세션 자기정정 감지)의 영향을 받았으면 true, 원문 발화만으로 독립 판단했으면 false' },
  },
  required: ['hasUpdate', 'summary', 'suggestedAddition', 'reasoning', 'supersedes', 'basedOnReflection'],
}

const REFLECTION_SCHEMA = {
  type: 'object',
  properties: {
    sessions: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          session: { type: 'string' },
          outcome: { type: 'string', enum: ['clean', 'corrected', 'unclear'] },
          note: { type: 'string', description: 'outcome이 corrected면 무엇을 어떻게 정정했는지(최종적으로 어느 방향으로 갔는지) 한 줄. 아니면 빈 문자열' },
        },
        required: ['session', 'outcome', 'note'],
      },
    },
  },
  required: ['sessions'],
}

const reflectionPrompt = `다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
각 발화에는 session(세션 ID)이 붙어 있다. 같은 세션 안의 발화들을 시간순으로 보고, 사용자가 세션 도중 자기 지시를 스스로 뒤집거나 정정한 흔적이 있는지 세션별로 판단해라.
정정의 신호 예시(전부는 아님, 참고용): "아니 그게 아니라", "다시 해줘", "롤백", "그거 말고", "잘못됐어" 같은 표현, 같은 요청을 다른 방식으로 다시 지시, 앞서 승인한 걸 뒤늦게 취소.
각 세션마다 outcome을 매겨라: 세션 안에서 사용자가 스스로 방향을 바꾼 게 뚜렷이 보이면 "corrected"(note에 최종적으로 어느 방향으로 정리됐는지 한 줄), 그런 흔적이 없으면 "clean", 발화가 너무 적거나 판단하기 애매하면 "unclear".
주의: 우리는 사용자 발화만 갖고 있고 어시스턴트 응답은 안 보인다 — 사용자 발화 자체에서 드러나는 자기정정만 판단해라(어시스턴트가 뭘 잘못했는지는 추측하지 마라). 애매하면 억지로 corrected로 몰지 말고 unclear로 남겨라.`

phase('리플렉션')
let reflectionSessions = []
try {
  const reflection = await agent(reflectionPrompt, { label: 'reflection', phase: '리플렉션', model: 'sonnet', schema: REFLECTION_SCHEMA })
  const sessions = reflection?.sessions
  if (!Array.isArray(sessions)) throw new Error('reflection.sessions가 배열이 아님(스키마 불일치)')
  reflectionSessions = sessions
  const correctedCount = reflectionSessions.filter((s) => s.outcome === 'corrected').length
  log(`리플렉션 완료 — ${reflectionSessions.length}개 세션 중 ${correctedCount}건 자기정정 감지`)
} catch (e) {
  reflectionSessions = []
  log(`리플렉션 실패(정정 감지 없이 계속 진행): ${e && e.message ? e.message : e}`)
}

// clean/unclear는 렌즈가 할 일이 없으니 토큰만 낭비 — corrected만 넘긴다.
const correctedSessions = reflectionSessions.filter((s) => s.outcome === 'corrected')
const REFLECTION_NOTE = correctedSessions.length > 0
  ? `\n\n자기정정이 감지된 세션 목록(JSON, 참고용 힌트일 뿐 — 그대로 베끼지 마라): ${JSON.stringify(correctedSessions)}
이 목록의 session에 해당하는 발화에서 패턴을 뽑을 땐, note에 적힌 최종 정정 방향을 우선 후보로 보되 반드시 그 세션의 원문 발화(위 데이터셋)를 직접 다시 읽어 note가 실제로 맞는지 스스로 판단해라 — 리플렉션은 다른 LLM의 1차 추정이라 틀릴 수 있다. note를 그대로 믿고 베끼지 말고, 원문과 다르면 원문 쪽을 따라라. 이 목록에 없는 session이나, session 값이 실제 데이터셋에서 안 보이면 이 규칙과 무관하니 평소대로 판단해라.
이 리플렉션 힌트의 영향을 받아 만든 제안이면 basedOnReflection을 true로 표시해라(원문 발화만으로 독립적으로 판단했으면 false).`
  : ''

const ROUTING_PROMPT = `너는 이 claude-config 환경의 3티어 에이전트 워크포스(Fable=기획/top, Opus 5=검증·리뷰·판정/mid, Sonnet=구현/exec — workload-optimization 스킬 §1·§5.10)가 지난 1주 실제로 얼마나 효율적으로 돌았는지 객관 수치로 분석해라. 이건 다른 렌즈와 달리 Vault 캐노니컬 문서를 고치는 게 아니라 라우팅 개선 "제안 드래프트"만 만드는 작업이다 — Vault 문서는 절대 건드리지 마라.

수집할 데이터(전부 Bash/Read로 네가 직접 조회해라, 실패하면 그 항목만 "데이터 없음"으로 남기고 계속 진행):
1. \`npx --yes ccusage@latest claude daily --json\` 실행 → 최근 7~14일 모델별(claude-fable-5 / claude-opus-5 계열 / claude-sonnet-5) 일별 cost 추이. 급증·급감이 있으면 짚어라.
2. \`~/.claude/model-relay/metrics.jsonl\` 존재하면 읽어서 stage(design/review/final)×tier(top/mid/exec)별 verdict(approve/reject) 분포와 반려율 계산. 없으면 "데이터 없음"이라고만 남겨라(추측 금지).
3. \`~/.claude/projects/-Users-evershongdae1/\` 아래 최근 세션들의 서브에이전트 위임 라벨(subagent_type 또는 Workflow agent() 호출의 label/phase)을 훑어서, 검증·리뷰·판정 성격(code-reviewer/security-reviewer/verifier/moderator/verdict류) 역할인데 model이 미지정이거나 top(Fable)로 실행된 사례(=workload-optimization §5.10 ②의 "미지정=버그" 위반, 또는 아직 이관 안 된 사례)를 셈해라. 전수조사는 불필요 — 표본 위주로 방향성만 잡아라.

위 데이터를 바탕으로 다음 형식의 마크다운 리포트를 작성해서, 있으면 다음 경로에 새 파일로 저장해라(Write 도구 사용): "${VAULT_90_HERMES}/라우팅제안/<오늘실제날짜 YYYY-MM-DD>_라우팅제안.md" (같은 날 재실행이면 "---" 구분선으로 새 절 이어붙이기). frontmatter: title/created/updated/category=라우팅제안/status=draft.

리포트 본문 구성:
- ## 지출 추이 (ccusage 실측)
- ## 반려율 (metrics.jsonl 실측, 없으면 "데이터 없음— 아직 릴레이 사용 이력 부족")
- ## 규약 위반/이관 후보 (역할×실효모델 적합성)
- ## 제안 (사람 승인 필요) — 예시 카테고리를 참고해 실제 데이터 기반으로만 작성해라(데이터 없으면 그 카테고리는 생략): "역할 X 반려율 낮음(표본 n건) → mid 계속/top 승격 검토", "역할 Y가 N건 미지정으로 실행됨 → §5.10 규약 리마인드", "티어 Z 지출이 전주 대비 M% 변화 → 재검토". 데이터가 불충분하면 억지로 결론 내지 말고 "표본 부족, 다음 주 재확인" 이라고 정직하게 적어라.

작업 후 2줄 이내로 요약해서 답하라: 파일을 실제로 썼는지(경로) 또는 못 썼다면(vault90HermesPath 없음 등) 그 이유, 그리고 이번 주 핵심 발견 1줄.`

phase('추출')
const [lensResults, routingSummary] = await parallel([
  () => Promise.all(LENSES.map((lens) =>
    agent(lens.prompt + REFLECTION_NOTE, { label: `lens:${lens.key}`, phase: '추출', model: 'sonnet', schema: LENS_SCHEMA })
      .then((r) => ({ ...lens, result: r }))
  )),
  () => VAULT_90_HERMES
    ? agent(ROUTING_PROMPT, { label: 'lens:routing', phase: '추출', model: 'sonnet' })
    : Promise.resolve(null),
])

if (VAULT_90_HERMES) {
  log(`라우팅 제안(lens:routing) 완료: ${routingSummary}`)
} else {
  log('라우팅 제안(lens:routing) 건너뜀 — vault90HermesPath 없음(구버전 run.sh)')
}

const withUpdates = lensResults.filter(Boolean).filter((l) => l.result?.hasUpdate)

// Phase 6: 재확인(실시간이 이미 잡았음) vs 신규(이번에 처음 잡힘 — 실시간이 놓쳤을 수 있음) 집계.
// 렌즈 단위 집계다(패턴 건수 아님 — 렌즈 1개가 신규+재확인을 동시에 내면 summary 접두사에 따라 한쪽으로만 잡힘, 최대 3).
// 새 렌즈·새 agent() 호출 없음 — 이미 있는 summary의 "[재확인]" 접두사만으로 판별(비용 불변).
// String()+trimStart(): summary가 숫자 등 비문자열이거나 앞에 공백이 붙어도 안전하게 판별.
const reconfirmedCount = withUpdates.filter((l) => String(l.result?.summary || '').trimStart().startsWith('[재확인]')).length
const newCount = withUpdates.length - reconfirmedCount
// 결정적 기록(0건 분기·LLM 복창 누락과 무관하게 항상 남음).
log(`추출 완료 — ${withUpdates.length}/${LENSES.length}개 렌즈에서 갱신 제안 발견 (재확인 렌즈 ${reconfirmedCount} / 신규 렌즈 ${newCount})`)

if (withUpdates.length === 0) {
  log('갱신할 새 패턴 없음 — 반영 단계 건너뜀')
} else {
  phase('종합/반영')
  const synthesisPrompt = `아래는 Vault 10_컨텍스트 캐노니컬 문서 3개 중 일부에 대해 렌즈별 분석 에이전트가 낸 갱신 제안이다.
각 제안을 검토해서, 실제로 반영할 가치가 있는 것만(중복/사소한 것 제외) 골라 해당 캐노니컬 파일을 직접 Edit해라.
현재 정책(vault-write.md, 2026-07-31): 이 볼트는 승인 게이트 없이 직접 쓰기가 허용된다 — _pending 제안 절차 쓰지 말고 바로 반영해라.

반영 시 지켜야 할 것:
- 각 파일 상단 frontmatter의 updated 필드를 오늘 날짜로 갱신
- 기존 문서의 어조/구조(제목 레벨, 표 형식 등)를 그대로 유지하며 자연스럽게 통합 — 통째로 갈아엎지 마라
- 3개 파일에 걸쳐 서로 모순되거나 중복되는 내용이 없게 조율 (hermes-agent 전달용 별도 파일은 쓰지 마라 — Vault가 정본이고, hermes-agent에는 hermes-sync.sh가 vault-context 블록으로 자동 전달한다)
- 반영 여부·강도를 정할 때 두 가지를 같이 봐라: (1) 확신도 — 근거가 얼마나 탄탄한가, (2) 위해도 — 만약 이 판단이 틀렸다면 앞으로의 세션들에 얼마나 잘못 퍼질까. 확신도가 낮거나 위해도가 높은 항목(특히 강점_약점_보완.md처럼 협업 방식 전반에 영향을 주는 문서)은 더 보수적으로("[관찰 중 · 잠정]" 태그, 표본 크기 명시 등) 반영해라.
- 렌즈가 summary를 "[재확인]"으로 표시한 제안은 새 문단을 추가하지 말고 해당 항목을 갱신해라. 먼저 그 항목에 이미 재확인 기록이 있는지 확인해라 — 서술형이든("...두 차례 반복 확인" 같은 문장) 태그형이든 이미 쓰인 표기 방식이 있으면 **그 방식을 그대로 따라** 갱신하고(새 형식을 억지로 섞지 마라), 그 항목에 재확인 기록이 전혀 없을 때만 새로 "(재확인: 1회, YYYY-MM-DD)" 형식을 도입해라. 카운트는 "이번 파이프라인 실행 1회 = 재확인 1회"로 센다 — reasoning에 그 실행에서 인용된 발화가 여러 건이어도 이번 실행에서는 1만 더한다(발화 건수만큼 여러 번 올리지 마라). 단, 같은 날짜에 여러 세션이 사실상 같은 사건을 동시에 보고한 경우(예: 병렬 터미널에 같은 지시를 브로드캐스트)는 애초에 독립적인 재확인이 아닐 수 있으니, 서로 다른 날짜·다른 맥락에서 나온 근거인지 먼저 판별한 뒤에만 반영해라.
- 대체대상(옛 supersedes)이 채워진 제안은 **비파괴적으로** 반영해라 — 그 기존 문장을 삭제하거나 덮어쓰지 마라. 먼저 그 파일에 이미 폐기/무효화를 표시하는 관례가 있는지 확인해라(재확인과 마찬가지로 서술형이든 태그형이든) — 있으면 그 방식을 그대로 따르고, 없을 때만 새로 "폐기됨(YYYY-MM-DD): <왜 바뀌었는지 한 줄>" 형식을 도입해라. 인용된 문장이 표(마크다운 테이블) 셀이나 리스트 중첩 안에 있어서 그 자리에 바로 끼워넣으면 표/리스트 구조가 깨질 경우, 셀/줄 안에 억지로 넣지 말고 그 표/블록 바로 아래에 별도 문장으로 "폐기됨(YYYY-MM-DD): <원문 요약> — <이유>" 형태로 남겨라. 새 판단은 근처에 별도 문장/불릿으로 추가해라(기존 문장은 그대로 남긴다 — 나중에 왜 판단이 바뀌었는지 추적할 수 있어야 한다). 대체대상에 인용된 문장을 그 파일에서 실제로 못 찾겠으면(문서가 이미 바뀌었거나 인용이 부정확한 경우) 억지로 짜맞추지 말고, 그 제안은 일반 신규 추가로 취급하고 이유를 반영 요약에 남겨라. 이 규칙은 대체대상이 채워진 제안에만 적용한다 — 순수 신규 추가(대체대상이 빈 문자열)까지 "폐기됨" 낙인을 찍지 마라.
- 리플렉션영향이 true인 제안은 렌즈 하나가 다른 LLM의 리플렉션 추정을 한 겹 더 거쳐 만든 재해석이다 — 원문 발화에서 바로 뽑은 제안보다 확신도를 한 단계 낮춰 취급해라(위 확신도×위해도 규칙과 같이 적용). 특히 강점_약점_보완.md처럼 위해도가 큰 문서에 반영할 땐 "[관찰 중 · 잠정]" 같은 보수적 표기를 우선 고려하고, 근거가 약하면 아예 보류해도 된다.
${VAULT_90_HERMES ? `- 감사 기록: 아래 렌즈별 제안을 검토해서 무엇을 어떻게 반영할지(또는 반영하지 않을지) **전부 최종 결정한 뒤**, 그 최종 결정 내용 그대로 ${VAULT_90_HERMES}/학습이력/ 안에 파일 하나를 먼저 써라. 파일명: 오늘 실제 날짜를 YYYY-MM-DD 형식으로 채운 뒤 "_학습분.md"를 붙인다 — 예: 2026-08-19_학습분.md(이건 형식 예시일 뿐이다, "오늘날짜"라는 글자를 그대로 파일명에 쓰면 안 되고 실제 오늘 날짜 숫자를 넣어야 한다). 그 파일이 이미 있으면(같은 날 두 번째 실행) 덮어쓰지 말고 "---" 구분선 + 실행 시각으로 새 절을 이어붙여라. 없으면 새로 만들어라(frontmatter: title/created/updated/category=학습이력/status=active/tags/related — related엔 이번에 실제로 손댈 캐노니컬 파일들을 [[위키링크]]로). 내용: (1) 아래 렌즈별 제안 전체를 그대로(요약·근거·대체대상·재확인여부·리플렉션영향 포함) (2) 이번에 실제로 반영하기로 결정한 것과, 반영 안 하기로 한 것(중복/사소해서 뺀 것 포함)과 그 이유. 이 감사 기록을 쓴 다음에 캐노니컬 노트를 편집해라 — 그리고 그 편집 내용은 감사 기록에 적은 결정과 정확히 일치해야 한다(편집 도중 계획이 바뀌면 — 예를 들어 대체대상 인용문을 캐노니컬 파일에서 못 찾아 신규 추가로 전환하는 경우 — 감사 기록도 그 최종 내용에 맞게 고쳐써서 둘이 어긋나지 않게 해라). 이 파일은 hermes-agent에 전달되는 대상이 아니다(vault-context 블록은 10_컨텍스트만 다룬다) — 순수 감사 기록용이니 hermes-agent 전달용 표현으로 다듬을 필요 없다.` : ''}

렌즈별 제안:
${JSON.stringify(withUpdates.map((l) => ({ 대상파일: l.file, 요약: l.result.summary, 제안내용: l.result.suggestedAddition, 근거: l.result.reasoning, 대체대상: l.result.supersedes || '', 리플렉션영향: !!l.result.basedOnReflection })), null, 2)}

작업 후 5줄 이내로 요약해서 답하라: 첫 줄은 반드시 "실시간 기록 감사: 재확인 렌즈 ${reconfirmedCount}개(이미 실시간에 잡혔음) / 신규 렌즈 ${newCount}개(이번에 처음 잡힘, 실시간이 놓쳤을 수 있음)" 그대로(숫자는 이미 계산돼 있으니 다시 세지 마라) — 그다음 줄들에 무엇을 어느 파일에 반영했는지.${VAULT_90_HERMES ? ' 그리고 감사 기록 파일을 실제로 썼는지 — 썼으면 정확한 경로, 못 썼거나 생략했으면 그 이유를 명시적으로 밝혀라(자기보고이니 사실대로).' : ''}`

  const synthesis = await agent(synthesisPrompt, { label: 'synthesis', phase: '종합/반영', model: 'opus' })
  log(`반영 완료: ${synthesis}`)
  if (VAULT_90_HERMES && !/학습이력|학습분\.md/.test(synthesis || '')) {
    log('⚠️ 감사 기록(90_Hermes/학습이력) 작성 여부가 synthesis 응답에서 확인 안 됨 — 다음 실행 시 직접 확인 필요')
  }
}

return {
  reflection: reflectionSessions,
  lensResults: lensResults.map((l) => ({ key: l.key, hasUpdate: l.result?.hasUpdate, summary: l.result?.summary })),
}
