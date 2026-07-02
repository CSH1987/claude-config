// claude-config: expert-debate — 범용 전문가 패널 토론 워크플로 (모든 머신에 배포됨)
// 사용: Workflow({ name: 'expert-debate', args: { topic: '...', context?: '경로|텍스트',
//        experts?: [{name, lens}], rounds?: 1-4(기본 2), outDir?: '저장 디렉터리' } })
// 구조: 전문가 구성 → 독립 기획(교차 오염 없음) → 공유·반박 라운드(수렴 시 조기 종료)
//        → 합의문(이견 부록 포함) → 교훈 추출(플레이북/에이전트 성장 제안 = 무한 성장 고리)
export const meta = {
  name: 'expert-debate',
  description: '분야별 전문가 에이전트가 독립 기획→상호 공유→토론(반박 라운드)→수렴→교훈 추출하는 범용 패널',
  whenToUse: '비자명한 기획·설계·의사결정을 다각화 시각으로 정밀하게 만들 때. args: {topic, context?, experts?, rounds?, outDir?}',
  phases: [
    { title: 'Panel', detail: '주제에 맞는 전문가 3~5인 구성' },
    { title: 'Position', detail: '전문가별 독립 기획서 작성' },
    { title: 'Debate', detail: '상호 공유·반박 라운드 (수렴 시 조기 종료)' },
    { title: 'Synthesize', detail: '합의문 + 이견 부록' },
    { title: 'Grow', detail: '교훈 추출 → 플레이북/에이전트 성장 제안' },
  ],
}

const topic = args && args.topic
if (!topic) throw new Error('args.topic 필요: Workflow({name:"expert-debate", args:{topic:"..."}})')
const ctx = (args && args.context) || '(추가 컨텍스트 없음)'
const rounds = Math.min(4, Math.max(1, (args && args.rounds) || 2))
const slug = String(topic).toLowerCase().replace(/[^a-z0-9가-힣]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40)
const outDir = ((args && args.outDir) || ('.omc/debate/' + slug)).replace(/\\/g, '/')

const DOC = { type: 'object', properties: { path: { type: 'string' }, summary: { type: 'string' } }, required: ['path', 'summary'] }
const PANEL = {
  type: 'object',
  properties: {
    experts: {
      type: 'array',
      items: {
        type: 'object',
        properties: { name: { type: 'string' }, lens: { type: 'string' } },
        required: ['name', 'lens'],
      },
    },
  },
  required: ['experts'],
}
const REBUTTAL = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    changed: { type: 'boolean' },
    concessions: { type: 'array', items: { type: 'string' } },
    challenges: { type: 'array', items: { type: 'string' } },
  },
  required: ['path', 'changed'],
}
const VERDICT = {
  type: 'object',
  properties: {
    converged: { type: 'boolean' },
    open_issues: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['converged', 'open_issues'],
}

const COMMON = `주제: ${topic}
공통 컨텍스트: ${ctx}
(컨텍스트가 파일 경로면 Read 도구로 먼저 읽어라. 관련 실제 파일·코드도 근거 확인차 Read 가능.)
규칙: 문서는 한국어(식별자·코드는 영어). 추측으로 사실을 단정하지 말 것 — 불확실하면 "검증 필요" 표시.
1인 운영자가 유지보수할 수 있는 수준을 기본 제약으로 삼고 과잉설계를 경계하라.`

// ── Panel: 전문가 구성 (args.experts 가 있으면 그대로 사용) ──────────────────
phase('Panel')
let experts = (args && args.experts) || null
if (!experts || !experts.length) {
  const panel = await agent(
    `${COMMON}

이 주제를 다각화 시각으로 정밀 설계하는 데 필요한 전문가 패널을 구성하라.
- 3~5명, 각자 서로 겹치지 않는 관점(lens)을 갖게 하라 (예: 아키텍처/비용·운영/보안·리스크/사용자가치/데이터).
- name 은 짧은 영어 식별자(kebab-case), lens 는 그 전문가가 파고들 질문 목록을 담은 한국어 2~4문장.
StructuredOutput 으로 {experts:[{name,lens}]} 반환.`,
    { label: 'panel', phase: 'Panel', schema: PANEL }
  )
  experts = (panel && panel.experts) || []
}
experts = experts.slice(0, 6)
if (experts.length < 2) throw new Error('전문가 2명 이상 필요 (panel 구성 실패)')
log(`패널 구성: ${experts.map(e => e.name).join(', ')}`)

// ── Position: 독립 기획 (서로의 결과를 보지 않음) ────────────────────────────
phase('Position')
const positions = await parallel(
  experts.map(e => () =>
    agent(
      `${COMMON}

당신은 "${e.name}" 전문가다. 관점: ${e.lens}

다른 전문가의 생각을 알지 못하는 상태에서, 이 주제에 대한 당신 관점의 기획/설계 입장문을 독립적으로 작성하라.
포함: ① 핵심 주장(번호) ② 설계/기획안 ③ 전제·가정 명시 ④ 당신 관점에서 절대 양보 못 할 원칙 ⑤ 다른 관점이 놓치기 쉬운 함정.
산출물: ${outDir}/position-${e.name}.md 에 Write (80~180줄). StructuredOutput: {path, summary(8줄 이내)}.`,
      { label: `position:${e.name}`, phase: 'Position', schema: DOC }
    )
  )
)
const alive = experts.filter((e, i) => positions[i])
if (alive.length < 2) throw new Error('입장문 2개 미만 — 토론 불가')
const paperPath = e => `${outDir}/position-${e.name}.md`

// ── Debate: 상호 공유 → 반박·수정 라운드 (수렴 시 조기 종료) ──────────────────
let verdict = null
let roundsRun = 0
for (let r = 1; r <= rounds; r++) {
  const others = me => alive.filter(e => e.name !== me.name).map(paperPath).join(', ')
  const rebuttals = await parallel(
    alive.map(e => () =>
      agent(
        `${COMMON}

당신은 "${e.name}" 전문가다. 관점: ${e.lens}
토론 라운드 ${r}/${rounds}. 당신의 현재 입장문: ${paperPath(e)}
다른 전문가들의 입장문: ${others(e)}
${verdict && verdict.open_issues && verdict.open_issues.length ? `사회자가 지정한 미해결 쟁점(우선 다뤄라): ${verdict.open_issues.join(' | ')}` : ''}

전부 Read 한 뒤:
1. 다른 입장문들의 가장 약한 전제·모순을 구체적으로 반박하라 (근거 필수, 인신공격식 총평 금지).
2. 타당한 지적은 수용해 당신 입장을 수정하라 — 방어가 아니라 더 나은 설계가 목표다.
3. 당신의 입장문(${paperPath(e)})을 갱신본으로 다시 Write 하라. 문서 끝에 "## 라운드 ${r} 변경 기록" 절을 두고
   수용한 것(concessions)과 남긴 반박(challenges)을 기록하라.
StructuredOutput: {path, changed, concessions:[...], challenges:[...]}.`,
        { label: `debate:r${r}:${e.name}`, phase: 'Debate', schema: REBUTTAL }
      )
    )
  )
  roundsRun = r
  verdict = await agent(
    `${COMMON}

당신은 토론 사회자다. 라운드 ${r} 종료 시점의 입장문 전부를 Read 하라: ${alive.map(paperPath).join(', ')}
판정하라: 실질적 쟁점(설계가 달라지는 이견)이 남아 있는가? 표현 차이·우선순위 취향 차이는 쟁점이 아니다.
StructuredOutput: {converged, open_issues(남은 실질 쟁점, 없으면 빈 배열), summary}.`,
    { label: `moderator:r${r}`, phase: 'Debate', schema: VERDICT }
  )
  const changed = rebuttals.filter(Boolean).filter(x => x.changed).length
  log(`라운드 ${r}: 입장 수정 ${changed}건, 미해결 쟁점 ${verdict ? verdict.open_issues.length : '?'}건`)
  if (verdict && verdict.converged) break
}

// ── Synthesize: 합의문 (이견은 숨기지 않고 부록으로) ─────────────────────────
phase('Synthesize')
const consensus = await agent(
  `${COMMON}

당신은 최종 편집자다. 모든 입장문(${alive.map(paperPath).join(', ')})을 Read 하고 합의 기획서를 작성하라.
구조: # 제목 / 0. 요약 / 1. 합의된 설계(각 항목에 어느 전문가 관점에서 왔는지 표기) / 2. 트레이드오프와 선택 근거
/ 3. 남은 이견 부록(전문가별 입장 병기 — 사회자 최종 판정: ${verdict ? JSON.stringify(verdict.open_issues) : '[]'})
/ 4. 실행 단계 / 5. 사용자 결정 필요 목록.
산출물: ${outDir}/consensus.md 에 Write (150~350줄). StructuredOutput: {path, summary(12줄 이내)}.`,
  { label: 'consensus', phase: 'Synthesize', schema: DOC }
)

// ── Grow: 교훈 추출 → 성장 제안 (토론이 에이전트를 성장시키는 고리) ────────────
phase('Grow')
const lessons = await agent(
  `${COMMON}

당신은 성장 추출자다. 이 토론의 전 과정(${alive.map(paperPath).join(', ')}, ${consensus ? consensus.path : ''})을 Read 하고,
"다음 토론/작업이 더 나아지게 만들 재사용 교훈"을 추출하라:
- 어떤 관점(lens)이 가장 가치 있는 반박을 만들었나 → 전문가 패널 구성 개선 제안
- 반복된 실수 패턴(잘못된 전제, 과잉설계 등) → 플레이북(~/.claude/playbooks/)에 추가할 규칙 제안
- 이 도메인에서 재사용할 지식 → 어디에 저장할지(위키/메모리 _pending) 제안
주의: 제안은 제안일 뿐 — 자동 반영 금지, 사람 검토(/retro→/promote 경로) 전제. PII 포함 금지.
산출물: ${outDir}/lessons.md 에 Write — 마지막 절은 "## 반영 제안 체크리스트"(사람이 승인/거부 표시할 수 있는 번호 목록).
StructuredOutput: {path, summary(8줄 이내)}.`,
  { label: 'lessons', phase: 'Grow', schema: DOC }
)

return {
  consensus: consensus,
  lessons: lessons,
  roundsRun: roundsRun,
  converged: verdict ? verdict.converged : false,
  openIssues: verdict ? verdict.open_issues : [],
  panel: experts.map(e => e.name),
  outDir: outDir,
}
