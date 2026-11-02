# Rodada 2 — mockups precisos para aprovação

Data: 2026-11-02. Estado: **proposta, aguardando aprovação**. Complementa [README.md](README.md) (rodada 1: auditoria VIS-001…009, inventário, três rasters de IA). Nenhum código de produção alterado.

## O que mudou em relação à rodada 1

Rodada 1 entregou imagens geradas por IA: boas para direção, imprecisas para implementação. Rodada 2 entrega **mockups HTML com valores exatos** (cores, tamanhos, espaçamentos, textos), mesma viewport e mesmo conteúdo entre direções. Rasters da rodada 1 = exploração de estilo; pranchas desta rodada = referência de implementação.

- Canvas (privado do dono): https://claude.ai/artifact/W7d6iCvNkgnGLvCfj2Q962
- Fonte local: [prototype/project/](prototype/project/) — `.dc.html` legíveis; valores podem ser copiados direto.

| Prancha | Arquivo | Viewport | Cobre |
|---|---|---|---|
| 01 Antes | `Antes.dc.html` | 1440×1024 | Capturas atuais (fixture) anotadas |
| 02 Aplicativos · A Ametista | `Main.dc.html` | 1440×1024 escuro | Tela densa: lista + detalhe, estados, CTA único |
| 03 Aplicativos · B Grafite | `AppsGrafite.dc.html` | idem | Mesma tela, paleta alternativa (comparação) |
| 04 Contas e conexões | `Contas.dc.html` | 1440×1024 claro | Conta × canal × provedor separados; privacidade |
| 05 Desenvolvimento | `Desenvolvimento.dc.html` | 1440×1024 escuro | Tarefa crítica preparar → validar → abrir + feedback de falha |
| 06 Steam Deck | `SteamDeck.dc.html` | 1280×800 | Rail, alvos 48 px, foco de controle, gate da pilha avançada |
| 07 Compacto | `Compacto.dc.html` | 800×600 | Rail sem rótulos, lista; detalhe em tela própria |
| 08 Prancha | `Componentes.dc.html` | 1440×1500 | Tokens, tipografia, espaço, raio, ícones, botões, campos, estados |

## Decisão recomendada

**Aprovar direção A “Ametista”.** Mantém violeta já presente na marca (bloco PZ, seleção atual), reduz custo de migração e preserva reconhecimento. B “Grafite” (teal) é coerente com o “ciano” citado em `linux/ui_native/UI-SPEC.md`, porém rompe com a marca vista nas capturas. Escolha pendente: se o operador preferir B, só trocar o mapa de tokens — layout idêntico.

Referência principal: **Microsoft Fluent 2** (app desktop nativo Windows + Linux, densidade média, tokens semânticos, foco explícito). Complementares: **Carbon** para lista/detalhe e status de dados; **Material 3** só para regras de estado (hover/pressed/disabled). Sem adotar biblioteca de nenhuma delas: Qt/QSS e WPF continuam nativos.

## Mudanças de fluxo (precisam aprovação explícita)

1. **Busca global vai para o cabeçalho** (Ctrl K). Página Aplicativos mantém só o filtro local, com rótulo próprio. Antes: duas buscas no corpo.
2. **“Comparar” vira ação secundária tracejada 0/2** com motivo em tooltip; seleção de comparação por linha fica para a implementação (não desenhada).
3. **Contas Codex:** “Organizar ícones e menu”, “Atualizar perfis” e “Limpar instalações personalizadas” entram no menu **Gerenciar ▾**. Ações por canal (Desktop/CLI/Web) ficam em linhas; uma primária por conta (Abrir Desktop).
4. **Desenvolvimento:** etapas numeradas; “Abrir ferramenta” bloqueado até validação passar (antes: três botões iguais sempre ativos). Confirmar se backend expõe esse estado; senão manter ativo com aviso.
5. **Barra de status:** “Cancelar” só aparece com operação em andamento.
6. **Navegação:** grupo “Desktop” (Aplicativos, Temas) e “Desenvolvimento e IA” são hipótese baseada no breadcrumb atual. Implementador usa grupos/IDs oficiais do registro de páginas; não reordenar por causa do mock.
7. **< 1024 px:** sidebar vira rail de ícones com `aria-label` e tooltip; detalhe abre em tela própria.

## Tokens (direção A)

Nomes semânticos; mapear para campos existentes de `ThemeTokens` em `linux/ui_native/tokens.py` (ex.: `surface_selected`, `focus_ring`) e equivalentes WPF em `bootstrap-ui.ps1`.

| Token | Escuro | Claro | Uso / contraste medido |
|---|---|---|---|
| `bg` | `#14151A` | `#F5F6FA` | Fundo de janela |
| `surface` | `#1E2028` | `#FFFFFF` | Painéis, cartões, campos |
| `surface-2` | `#282B35` | `#EEF0F5` | Botão secundário, badge neutro |
| `surface-selected` | `#2A2540` | `#EDE8FC` | Item de nav/linha selecionada (texto 13,3 / 13,1:1) |
| `border` | `#30333F` | `#DCDFE7` | Divisores (decorativo) |
| `control-border` | `#6B7080` | `#868C9C` | **Novo.** Borda de campo/botão/chip: 3,7 / 3,4:1 sobre bg (WCAG 1.4.11) |
| `text` | `#F3F4F7` | `#20232D` | 14,8 / 15,7:1 |
| `text-secondary` | `#B0B5C3` | `#5E6677` | ≥6,9 / ≥5,1:1 em todas as superfícies |
| `accent` | `#7854E8` | `#6540D8` | Botão primário (branco 5,0 / 6,4:1) |
| `accent-text` / `focus-ring` | `#B39AF5` | `#6540D8` | Ícone ativo, link, anel 3 px (6,9:1) |
| `success` / `-bg` | `#77D6A3` / `#1D3329` | `#186C4E` / `#E3F3EC` | 7,7 / 5,6:1 |
| `warning` / `-bg` | `#F4C26A` / `#3A2F1A` | `#875500` / `#FBF0DC` | 8,0 / 5,6:1 |
| `error` / `-bg` | `#FF9696` / `#3A2024` | `#B72D43` / `#FBE6E9` | 7,1 / 5,1:1 |
| `info` / `-bg` | `#8FB8FF` / `#1F2A40` | — (definir) | 7,2:1 |

Grafite (B): `bg #10161C`, `surface #1A242D`, `surface-2 #22303A`, `selected #173532`, `control-border #6A7C8A`, `text #EAF1F3`, `secondary #A6B7C5`, `accent #67D5BC` com texto `#0E1A17` (10,0:1).

`text_muted` atual (2,67:1) **não** deve ser usado para texto; só decoração/indisponível com motivo textual.

Tipografia: Inter/Noto Sans (Linux), Segoe UI (Windows). Escala: 32/40 display · 28/36 título de página · 18/24 seção · 15/22 corpo (base) · 14/20 rótulo/botão · 13/18 secundário · 12/16 meta (só dispensável). Pesos 400/500/600.
Espaço: base 4; ritmo 4/8/12/16/24/32/40/48. Página: padding 24×32; gap entre blocos 24; lista 4.
Raio: 6 badge · 8 controle · 10 linha/logo · 12 cartão/diálogo. Elevação: só menu/diálogo/toast (`0 8px 24px rgba(0,0,0,.45)`).
Alvos: 40 px desktop (mín. 36 em ações densas), 48 px Steam Deck; nav 36 px de altura com largura total.
Movimento: 120–180 ms em hover/seleção; sem shimmer quando movimento reduzido.

## Componentes

| Manter | Ajustar | Substituir | Criar |
|---|---|---|---|
| Sidebar agrupada, breadcrumb, toggle Modo avançado, barra de status, preview → confirmar | Botões (4 variantes + indisponível tracejado), campos (borda 3:1, foco 3 px), badges (rótulo+ícone+cor), cabeçalho (busca global) | Botões largos da lista de apps → linhas com logo/nome/descrição/estado; glifos WPF de navegação → Lucide | Painel de detalhe de app, stepper de etapas, lista de checagens PASS/WARN/FAIL, linha conta×canal, rail compacto, dica de botões de controle (Deck) |

## Ícones e assets

- Família funcional: **Lucide** (licença ISC). Fixar versão, copiar só o subconjunto usado para `assets/icons/ui/` com `LICENSE`. Grade 24, traço 1,75 (2 em 14–16 px), cantos/pontas arredondados, `currentColor`. Tamanhos 16/20/24; 32 só em cartões de modo do Deck. Contorno sempre; preenchido não usado (estado ativo = cor `accent-text` + fundo selecionado).
- Paths nos mocks são aproximações desenhadas à mão na grade Lucide para revisão; implementar com os SVGs oficiais dos nomes: `house, layout-dashboard, terminal-square, layers, gamepad-2, monitor, smartphone, server, house-wifi (ou house + wifi), library, rotate-ccw, package, puzzle, sliders-horizontal, folder-code, key-round, bot, plug, network, layout-grid, palette, history, app-window, terminal, globe, search, funnel, refresh-cw, circle-check, triangle-alert, circle-x, loader-circle/circle-dashed, chevron-right, menu`.
- Personalizados (não existem na família): modos Portátil / Dock TV e “Restaurar controles” — desenhar na mesma grade 24/1,75 e registrar origem.
- Linux: rótulo “Linux” usa logo da distro instalada quando existir (regra da rodada 1); fallback `terminal-square`.
- Logos de terceiros (apps, Codex, provedores): arquivo original local, slot 40/64 px, 75% da área, sem recolor/contorno; ausência → monograma neutro. Nada baixado durante render.
- Badges de loja (App Store, Google Play, Microsoft Store, Steam): **não usar** — PhaseZero não é distribuído por esses canais. “Steam Deck” só como texto.
- Defeitos VIS-001/002/007/009 continuam pré-requisito (gerador de SVG, `.desktop` sem `Icon=`, ICOs).

## Comportamentos não visíveis nas imagens

- Foco: anel 3 px `focus-ring`, offset 2; ordem Tab = cabeçalho → nav → conteúdo → detalhe → status. Linha de app ativável por Enter/Espaço; setas ↑↓ na lista.
- Seleção de linha atualiza detalhe sem mover foco; < 1024 px abre tela de detalhe com voltar.
- Indisponível: sempre motivo visível (texto) além do tooltip; leitores de tela recebem o motivo via `accessibleDescription`.
- Estados de verificação: “Não verificado” é o padrão até prova; nunca converter em sucesso.
- Feedback: falha → alerta inline com causa curta + ação primária corretiva + “Detalhes técnicos” recolhido; sucesso → toast com Desfazer quando reversível.
- Texto longo: nomes quebram em 2 linhas no detalhe; descrição da lista trunca com reticências e mostra completo no detalhe/tooltip.
- Deck: L1/R1 trocam seção, A seleciona, B volta; hints na barra inferior.

## Prioridade e dependências

1. P0 — VIS-001 (gerador SVG) + tokens `control-border`, escala 15 px, `text_muted` fora de texto. Desbloqueia todo o resto.
2. P1 — Cabeçalho com busca global, sidebar com Lucide, botões/campos/badges. Tela piloto Aplicativos (lista + detalhe).
3. P1 — Contas e Desenvolvimento (fluxos 3 e 4 acima, após aprovação).
4. P2 — Rail < 1024 px e Steam Deck 48 px; WPF com mesmos tokens.
5. P2 — Demais 18 páginas pela matriz da rodada 1.

## Critérios de aceite

- Todo texto ≥ 4,5:1; borda de controle e foco ≥ 3:1 sobre superfície real; gate de contraste inclui os pares desta tabela.
- Nenhum estado comunicado só por cor (rótulo + ícone presentes).
- Uma ação primária por contexto em Aplicativos, Contas (por conta) e Desenvolvimento (por etapa).
- 800×600, 1280×800, 1440×1024 a 100/150/200%: sem rolagem horizontal, sem CTA cortado.
- Ícones Lucide oficiais na versão fixada, licença no repositório; nenhum quadrado preto em claro/escuro/alto contraste.
- Paridade Qt × WPF nos tokens; capturas antes/depois anexadas ao handoff.
- Teclado, leitor de tela, controle do Deck e movimento reduzido testados no app real (não verificáveis no mock).

## Verificado nesta rodada × pendente

Verificado: contraste calculado (WCAG 2.x) de todos os pares texto/fundo e borda/fundo usados nos mocks; correção aplicada após primeira versão (bordas 1,29:1 → `control-border`; glifos ✓/! trocados por ícones). Fonte HTML revisada.

Não verificado: **render visual das pranchas** — o browser do agente exige login no claude.ai; operador deve abrir o canvas. Navegação por teclado, leitor de tela, Qt/WPF reais, HiDPI. Descrições e estados de apps/contas/provedores são ilustrativos (fixture real mostra tudo “Não verificado”). Ícones são aproximações à mão.

Pendências de decisão: direção A ou B; aprovação das mudanças de fluxo 1–7; manter ou não “Comparar”; família Lucide vs. outra aberta (Phosphor, Tabler) se houver restrição.


## Rodada 3 — temas retrô (aprovada e implementada)

Operador rejeitou Ametista/Grafite e aprovou paletas de consoles antigos. Canvas
atualizado: prancha 09 lista os 8 temas; pranchas 02–08 usam SNES (claro) e PS2 /
Mega Drive (escuros). Implementação Qt em `linux/ui_native/tokens.py` (`THEMES`,
`tokens_for`), seletor no botão de tema do cabeçalho, preferência persistida em
`interface/theme`. Superfícies/estados derivados das cores-fonte e ajustados até
passar em `a11y.CONTRAST_PAIRS` (texto 4,5:1, foco 3:1). WPF (`bootstrap-ui.ps1`)
não recebeu os temas nesta entrega.
