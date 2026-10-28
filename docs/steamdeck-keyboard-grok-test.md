# Roteiro: teclado no terminal e no Grok CLI (Steam Deck)

Objetivo: descobrir qual teclado entrega texto ao Grok CLI 1.0.70. Ele é uma
interface de terminal (ratatui/crossterm) que liga o protocolo de teclado
"kitty" e espera eventos de tecla, não texto pronto.

Antes de começar:

```
linux/pz steamdeck input status        # mode deve ser "desktop"
linux/pz steamdeck keyboard status | jq .competingInputMethods   # deve ser []
```

Para cada linha da tabela, abra o Ashyterm, rode o programa da coluna e
digite `abc`, Backspace, Enter e uma seta. Anote ✓ ou ✗.

| # | Teclado | Como abrir | bash puro | `grok` |
|---|---------|------------|-----------|--------|
| 1 | Teclado KDE (plasma-keyboard) | tocar no terminal (watcher ligado) ou atalho do teclado | | |
| 2 | Teclado do Steam | **Steam + X** | | |
| 3 | Teclado físico/Bluetooth | — | | |

Repita a linha 1 no Konsole, se estiver instalado (`konsole -e grok`), para
separar terminal de teclado.

Como ler o resultado:

- **1 ✗ no Grok e ✓ no bash, 2 ✓:** o Grok não aceita texto de input method.
  Para ele, use Steam + X. O PhaseZero pode mapear um botão para abrir o
  teclado do Steam no terminal.
- **1 ✗ também no bash:** o teclado não chega ao terminal. O watcher
  `phasezero-terminal-keyboard` precisa estar ativo:
  `linux/pz steamdeck terminal-keyboard persist-on`.
- **Tudo ✗ só no Grok:** o problema é do Grok. Teste
  `TERM=xterm-256color grok` e reporte ao upstream.

Mande a tabela preenchida para a próxima etapa.
