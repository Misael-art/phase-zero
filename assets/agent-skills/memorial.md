# Práticas de produção do PhaseZero

Estas práticas orientam desenvolvimento, diagnóstico e continuidade nos projetos que adotam o PhaseZero. Aplique cada prática no contexto do trabalho autorizado, respeitando as instruções atuais do usuário e os requisitos versionados do projeto.

## Preparar o trabalho

- Identifique o projeto, o fluxo oficial, o responsável pelo componente e o critério de aceite. Leia as regras locais e o roadmap da frente quando houver.
- Consulte a memória do projeto por decisões, procedimentos e falhas semelhantes. Antes de reaplicar uma orientação, confira escopo, origem, data e decisões posteriores no checkout e no ambiente atuais. Sessões, resultados de busca e relatórios de lint servem como evidência. Para adotar práticas compartilhadas, use a revisão marcada como `practices-verified`. Se estiver indisponível, siga as regras versionadas e use o memorial do checkout como referência.
- Preserve a raiz canônica, as mudanças de outras tarefas e os dados existentes. Integre a solução ao fluxo que já atende o projeto e limite a mudança ao comportamento solicitado.

## Validar e entregar

- Reproduza a falha ou estabeleça uma verificação inicial. Use os comandos oficiais e exercite a entrada normal do produto com dados controlados. Cubra a regressão e os limites do ambiente que podem mudar o resultado.
- Registre separadamente o que foi observado em fixture, CI, sistema operacional e equipamento físico. Para cada gate pendente, indique o alvo necessário e como repetir a verificação.
- Antes de publicar um incremento autorizado, confira o destino, o diff, os checks e a presença de dados privados. Registre o SHA, os resultados e o próximo passo no handoff existente. Siga as permissões do projeto para merge, publicação e deploy.

## Projetar e implementar a experiência

Use o Fôlego como caso de hierarquia, leitura de estado e adaptação a espaços reais. Use o RetroDev Studio como caso de continuidade na edição, escopo das ações e validação pelo produto. Separe proposta, protótipo e comportamento comprovado. Aproveite a intenção e a forma de verificar cada decisão. Composição, tipografia, cores, componentes e movimento seguem a identidade do projeto de destino.

- No planejamento, descreva quem usa a interface, o ponto de entrada, a tarefa e o resultado perceptível. Em cada etapa, defina o que a pessoa precisa perceber, decidir e fazer. Destaque estado e ação principal. Deixe diagnóstico e opções avançadas acessíveis.
- Na implementação, preserve orientação, foco, seleção e alterações ao mudar de área quando a tarefa exigir. Explicite se a ação afeta o item, um recurso compartilhado ou o projeto. Use os fluxos oficiais para cancelar, desfazer, salvar, reabrir e recuperar.
- Diferencie carregamento, vazio confirmado, leitura parcial, dado antigo, edição pendente, erro, bloqueio e sucesso. Use texto além de cor e feedback perto da ação. Mostre causa e recuperação quando disponíveis. Preserve contraste, foco visível, área de clique e separação entre digitação e atalhos.
- Adapte a composição à largura, altura e zoom reais. Exercite títulos longos, conteúdo cheio, atalhos abertos, rolagem e alcance do último item. Confira margens, alinhamento, legibilidade e consistência. Use movimento para explicar mudança de estado. Teste teclado, ponteiro e toque conforme o destino.
- Percorra a jornada pelo ponto de entrada normal até o resultado. Exercite erro ou cancelamento e retorno à tarefa. Se houver persistência, salve e reabra. Para cada ajuste relevante, registre problema, decisão, critério de aceite e evidência comparável. Separe inspeção estática, automação, execução real e avaliação com participantes.

## Preservar a continuidade

- Registre aprendizados duráveis na memória do projeto com sintoma, causa, correção, evidência e ambiente. Use os hooks configurados para a atividade de rotina. Se a memória estiver indisponível, preserve o achado no handoff existente.
- Trate o GitHub privado e a mídia cadastrada como destinos de pacotes cifrados. A leitura cotidiana usa a instância local. Preserve a identidade do projeto, os backups de cada host e a separação entre chave de recuperação e assinatura do curador.
- Promova um aprendizado a prática compartilhada somente após revisão do curador. Publique uma revisão assinada maior quando uma prática mudar ou for revogada. As regras obrigatórias do projeto ficam na orientação local e nos gates que as executam.
