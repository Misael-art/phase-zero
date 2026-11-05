# Práticas de produção do PhaseZero

Estas práticas orientam desenvolvimento, diagnóstico e continuidade nos projetos que adotam o PhaseZero. Aplique cada prática no contexto do trabalho autorizado, respeitando as instruções atuais do usuário e os requisitos versionados do projeto.

## Preparar o trabalho

- Identifique o projeto, o fluxo oficial, o responsável pelo componente e o critério de aceite. Leia as regras locais e o roadmap da frente quando houver.
- Consulte a memória do escopo atual por decisões, procedimentos e falhas semelhantes. Abra as páginas pertinentes e confronte as informações com o checkout e o ambiente atuais. Trate resultados de busca e passagens de contexto como evidência histórica.
- Preserve a raiz canônica, as mudanças de outras tarefas e os dados existentes. Integre a solução ao fluxo que já atende o projeto e limite a mudança ao comportamento solicitado.

## Validar e entregar

- Reproduza a falha ou estabeleça uma verificação inicial. Use os comandos oficiais e exercite a entrada normal do produto com dados controlados. Cubra a regressão e os limites do ambiente que podem mudar o resultado.
- Registre separadamente o que foi observado em fixture, CI, sistema operacional e equipamento físico. Para cada gate pendente, indique o alvo necessário e como repetir a verificação.
- Antes de publicar um incremento autorizado, confira o destino, o diff, os checks e a presença de dados privados. Registre o SHA, os resultados e o próximo passo no handoff existente. Siga as permissões do projeto para merge, publicação e deploy.

## Preservar a continuidade

- Registre aprendizados duráveis na memória do projeto com sintoma, causa, correção, evidência e ambiente. Use os hooks configurados para a atividade de rotina. Se a memória estiver indisponível, preserve o achado no handoff existente.
- Trate o GitHub privado e a mídia cadastrada como destinos de pacotes cifrados. A leitura cotidiana usa a instância local. Preserve a identidade do projeto, os backups de cada host e a separação entre chave de recuperação e assinatura do curador.
- Promova um aprendizado a prática compartilhada somente após revisão do curador. Publique uma revisão assinada maior quando uma prática mudar ou for revogada. As regras obrigatórias do projeto ficam na orientação local e nos gates que as executam.
