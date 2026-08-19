export const meta = {
  name: 'vault-learning-pipeline',
  description: 'Claude Code(+Hermes) 대화에서 패턴을 뽑아 Vault 10_컨텍스트를 갱신 (hermes-agent 전달은 hermes-sync.sh의 vault-context 블록이 담당 — 2026-08-19 SOOHA_CONTEXT 레그 제거)',
  phases: [
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

const LENSES = [
  {
    key: 'ai-collab',
    file: `${VAULT}/AI_협업_패턴.md`,
    prompt: `이 파일을 읽어라: ${VAULT}/AI_협업_패턴.md (기존 캐노니컬 문서 — 활동 프로파일/지시스타일/교정루프/세션운용/표기체계 섹션 구조).
다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
건수·세션수·기간은 파일 안에서 직접 확인해라(이 프롬프트에 미리 적힌 숫자는 없다 — 매 실행마다 실제 파일 크기가 다르다). 표본이 작으면(수십 건 미만 등) 그 사실 자체를 근거 판단에 반영해라.
이 데이터에서 기존 문서의 각 섹션에 추가하거나 갱신할 만한 새로운 패턴이 있는지 분석하라 — 없으면 없다고 정직하게 답하라(표본이 작으면 새 패턴이 없는 게 정상일 수 있다). 억지로 만들어내지 마라.
기존 문서를 직접 고치지 마라 — 이 단계는 제안만 한다.`,
  },
  {
    key: 'principles',
    file: `${VAULT}/업무_원칙_방법론.md`,
    prompt: `이 파일을 읽어라: ${VAULT}/업무_원칙_방법론.md (검증된 판단 규칙만 수록하는 캐노니컬 문서).
다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
건수·세션수·기간은 파일 안에서 직접 확인해라(이 프롬프트에 미리 적힌 숫자는 없다 — 매 실행마다 실제 파일 크기가 다르다).
이 데이터에서 새로 검증된 업무 판단 규칙(반복 적용 가능한 원칙)이 있는지 분석하라 — 없으면 없다고 정직하게 답하라. 1회성 프로젝트 상태 정보(예: "베가스 CRM 확인해줘" 같은 단발 지시)는 원칙이 아니므로 제외하라.${MEMORY_DIR ? ` 사용자 auto-memory(${MEMORY_DIR})에 이미 같은 취지로 기록된 항목이 있는지도 확인해서 교차검증에 활용해라.` : ''}
기존 문서를 직접 고치지 마라 — 이 단계는 제안만 한다.`,
  },
  {
    key: 'strengths-weaknesses',
    file: `${VAULT}/강점_약점_보완.md`,
    prompt: `이 파일을 읽어라: ${VAULT}/강점_약점_보완.md (자기분석 + 보완장치 캐노니컬 문서).
다음 사용자 발화 데이터셋을 읽어라: ${UTTERANCES_PATH}
건수·세션수·기간은 파일 안에서 직접 확인해라(이 프롬프트에 미리 적힌 숫자는 없다 — 매 실행마다 실제 파일 크기가 다르다). 표본이 작으면 그 사실 자체를 근거 판단에 반영해라.
이 데이터에서 기존에 기록된 강점/약점/보완장치와 관련해 새로 확인되거나 갱신할 만한 근거가 있는지 분석하라 — 없으면 없다고 정직하게 답하라.
기존 문서를 직접 고치지 마라 — 이 단계는 제안만 한다.`,
  },
]

const LENS_SCHEMA = {
  type: 'object',
  properties: {
    hasUpdate: { type: 'boolean' },
    summary: { type: 'string', description: '변경 제안 요약, 없으면 빈 문자열' },
    suggestedAddition: { type: 'string', description: '문서에 추가/수정할 구체 문구(마크다운), 없으면 빈 문자열' },
    reasoning: { type: 'string', description: '근거가 된 발화/패턴 설명' },
  },
  required: ['hasUpdate', 'summary', 'suggestedAddition', 'reasoning'],
}

phase('추출')
const lensResults = await parallel(LENSES.map((lens) => () =>
  agent(lens.prompt, { label: `lens:${lens.key}`, phase: '추출', model: 'sonnet', schema: LENS_SCHEMA })
    .then((r) => ({ ...lens, result: r }))
))

const withUpdates = lensResults.filter(Boolean).filter((l) => l.result?.hasUpdate)
log(`추출 완료 — ${withUpdates.length}/${LENSES.length}개 렌즈에서 갱신 제안 발견`)

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

렌즈별 제안:
${JSON.stringify(withUpdates.map((l) => ({ 대상파일: l.file, 요약: l.result.summary, 제안내용: l.result.suggestedAddition, 근거: l.result.reasoning })), null, 2)}

작업 후 무엇을 어느 파일에 반영했는지 3줄 이내로 요약해서 답하라.`

  const synthesis = await agent(synthesisPrompt, { label: 'synthesis', phase: '종합/반영', model: 'opus' })
  log(`반영 완료: ${synthesis}`)
}

return { lensResults: lensResults.map((l) => ({ key: l.key, hasUpdate: l.result?.hasUpdate, summary: l.result?.summary })) }
