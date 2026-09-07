# Reconciliação dos 31 itens anteriores

Todos estão `verified` no backlog do agente. Esta tabela distingue alteração implementada de aceite integral; nenhum rótulo anterior foi sobrescrito. Não equivale a reexecutar os 31 cenários em hosts reais.

| Item | Parecer independente |
|---|---|
| PZ-AUD-001 | Entrypoint empacotado implementado; asset novo instalado por usuário comum e bridge inicial ainda precisam E2E. |
| PZ-AUD-002 | Preparo real implementado; UI não consegue consumir seu plano multilinha (REV-004); host limpo não certificado. |
| PZ-AUD-003 | Ordenação/propagação melhoradas; instalação completa dos perfis não exercitada nesta revisão. |
| PZ-AUD-004 | Compose passou a ser consumido; seleção do onboarding não governa apps (REV-007). |
| PZ-AUD-005 | Erros parciais melhorados, trecho correspondente da suíte passou; não equivale à prontidão funcional. |
| PZ-AUD-006 | Estado mais rigoroso; healthchecks/sondas exigem E2E por app e falhas transitórias. |
| PZ-AUD-007 | Broker Paperless e dependências adicionados; OCR/importação real pendentes. |
| PZ-AUD-008 | Metadados de primeiro uso e probes não provisionam todos os casos de uso; docs continuam preview. |
| PZ-AUD-009 | Reabrir: captura de SQLite/copias vivas não prova consistência (REV-002). |
| PZ-AUD-010 | Reabrir P0: perda parcial e rollbackApplied enganoso reproduzidos (REV-001/003). |
| PZ-AUD-011 | Isolamento por labels/nome de volume melhorado; container_name fixo ainda impede coexistência completa. |
| PZ-AUD-012 | Reconcile/estado desejado adicionados; reboot real por conjunto ainda pendente. |
| PZ-AUD-013 | Reabrir: parser, pareamento, host binding e seleção quebrados (REV-004..007). |
| PZ-AUD-014 | Reabrir jornada leiga: porta/chave melhores, primeiro contato ainda exige terminal (REV-008). |
| PZ-AUD-015 | Start/enable e probes adicionados; linger, conta/TLS e reboot sem login precisam prova. |
| PZ-AUD-016 | Toolchain/build mais defensivos; dependências de navegador/9Router e host limpo permanecem pendentes. |
| PZ-AUD-017 | Checagem explícita de build presente; suíte proxies passa. Certificação real ainda limitada. |
| PZ-AUD-018 | Conjunto supported unificado; validade de cada integração depende de autenticação real. |
| PZ-AUD-019 | Reabrir paridade: manifesto explicita migração Windows ainda não executada (REV-016). |
| PZ-AUD-020 | Probe MiMo Linux melhorado; inferência real e Windows pendentes. |
| PZ-AUD-021 | Hermes opcional/bloqueado honesto; objetivo instalação pronta ainda não entregue. |
| PZ-AUD-022 | Perfis agora explicitamente não instaláveis; limitação comunicada, não implementação de appliances (REV-018). |
| PZ-AUD-023 | ADR limita promessa a política de instalação; execução isolada continua futura, não concluída. |
| PZ-AUD-024 | Pull síncrono e probe melhorados; cold load/modelo real não exercitados. |
| PZ-AUD-025 | Timeout passa executável corrigido; reboot com serviço real não provado. |
| PZ-AUD-026 | Provider oficial/AUR e required_by melhorados; variante limpa requer instalação real. |
| PZ-AUD-027 | Manifestos e multilib melhorados; teste local passa, job remoto novo ainda sem execução. |
| PZ-AUD-028 | Reabrir: definição de CI não é prova de CI; matriz continua incompleta (REV-017/018). |
| PZ-AUD-029 | Reabrir: objetivos somados a UI técnica, controles cortados (REV-014/015). |
| PZ-AUD-030 | Pins/ro/rotação/rede/checks adicionados; receitas precisam runtime funcional e isolamento E2E. |
| PZ-AUD-031 | MemAvailable/reserva VM melhorados; orçamento sob concorrência, disco/VRAM não certificado. |
