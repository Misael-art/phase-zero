# Revisão independente UX-001..004 — 97fb085

**Aceite parcial: UX-002 passou; UX-001 permanece bloqueado; UX-003/004 melhoraram, mas ainda cortam controles com tema real.** Os três commits existem, worktree do agente limpa. Nenhum código de produto alterado nesta revisão.

## Validação

- **115 pytest passed**: Player47, Windows VM30, agente/web38. [Saída](pytest.txt).
- [Provas independentes](probes.json): memória16000→15999 mantém execução; botão confirmar oculto; geometria com tema real e8 ciclos de processEvents.
- [Harness completo](check.py), [QA isolada](qa.py): `python reports/review-ux004-2026-09-07/qa.py`. HOME/XDG temporários, ambiente allowlist, serviços bloqueados, status/UI probes interceptados.
- Não reexecutei pytest completo, falha dualscreen alegada ou suíte shell sem mudanças. Não certifico a classificação pré-existente da falha completa independentemente nesta rodada.
- Não testei escala150/200%, leitor de tela, touch físico ou usabilidade com participantes.

## 1. UX-001: confirmação ainda inacessível

`linux/ui_native/pages/homelab.py` contém **duas** definições de `_refresh_onboard_label`, linhas340 e359. Python usa a segunda, que só atualiza label e apaga o comportamento que mostraria o botão.

Na etapa review com janela mostrada: `hidden:true`, `enabled:true`, `visibleRegionEmpty:true`. Avançar mantém `confirmed:false` e etapa review. O teste verde usa `isVisible() or isEnabled()`: aceita botão oculto habilitado e QTest envia clique diretamente a ele. Isso não prova que o usuário pode clicar.

Correção e aceite: eliminar definição duplicada; no teste, exigir botão visível **e** habilitado, retângulo inteiro alcançável, depois executar clique. Interação deve passar pelo controle apresentado. Criar checagem dirigida para métodos duplicados nas classes alteradas é útil como prevenção.

## 2. UX-002: aceite local

Comparação exclui budget variável e revalida verdict fail antes da execução. Repeti planos reais com16000 e15999MiB: mesmos apps/pass e execução disparada. Suite também cobre mudança de apps e limite recusado. Isso fecha o defeito de drift; não certifica token transacional no backend ou todas corridas de recursos.

## 3. UX-003/004: tema real ainda quebra largura

Capturas usam MainWindow e `apply_theme(app, "dark")`, não página isolada com estilo Qt padrão. Probes de serviços estão interceptados; “verificando” nas capturas não é defeito de prontidão avaliado.

| Página em800x600 | Evidência |
|---|---|
| Homelab | overflow horizontal70px; barra desligada; Atualizar/Avançar cortados. |
| Windows VM | overflow horizontal57px; botão Iniciar termina emx765, viewport termina737. |

Homelab ganhou espaço vertical, mas precisa reflow de header/linhas. Windows ganhou cards empilhados, mas texto e grid de ações do hero ainda ficam lado a lado. `visibleRegion` não vazio e largura mínima de150px não provam visibilidade completa.

[Homelab800](Homelab-800.png) · [Windows800](Windows-VM-800.png) · [Homelab1280](Homelab-1280.png) · [Windows1280](Windows-VM-1280.png).

Aceite necessário: janela real do app + stylesheet, todas ações públicas, `horizontalScrollBar.maximum()==0` e retângulo inteiro de cada botão dentro do viewport após rolagem. Testar alternância800→1280→800. Incluir controles do header, onboarding, manutenção e ação principal; não apenas lista de ações.

## Próximo trabalho

1. Fechar duplicação e teste permissivo de UX-001.
2. Reflow real de UX-003/004, com geometria e tema do app.
3. Avançar UX-005/007/009 como agente propõe: modo simples, instalação distinta de orçamento, configurar acesso e abrir solução pronta.
4. R2 primeiro acesso e R3 contrato gráfico continuam pendentes; escalas/acessibilidade devem integrar gates, não ser inferidas de testes de handler.

Fila devolvível ao agente: [backlog.json](backlog.json). Preserva IDs existentes e informa causa, correção e teste que faltou.

## Handoff

```text
Objetivo: conferir retorno UX-001..004 com tema real.
IDs: UX-001 reabrir; UX-002 aceite local; UX-003/004 parciais.
Branch/worktree: codex/review-ux004; /mnt/sdcard/Projects/pz-review-ux004.
HEAD inicial:97fb085; final: commit documental via git log.
Arquivos: reports/review-ux004-2026-09-07; notas em roadmaps Homelab/REV.
Testes:115 pytest verdes; probes e6 capturas com tema real.
CI/PR: nenhum; suíte completa não reexecutada.
Host: sem alteração de serviços/VM/workloads/boot/pacotes.
Segredos: ambiente allowlist, fixtures, revisão do diff; gitleaks não executado.
Limites: não certifica release ou hardware; sem escala150/200%.
Próximo: remover método duplicado; teste exige controle visível antes do clique; reflow horizontal com tema real.
```
