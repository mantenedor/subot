# managed-host-gate/etc

`telegram.env` (gerado a partir de `telegram.env.example` por `install-gate.sh`, nunca versionado)
guarda `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` e `TELEGRAM_AUTHORIZED_IDS` — os únicos segredos
do gate de escalação de privilégio (`../bin/subot-gate-daemon.sh`). Vive em
`/opt/subot-gate/etc/telegram.env`, `root:root 0600`, no host gerenciado.

## Modelo de ameaça: o que essa permissão protege, e o que ela não protege

O modelo de ameaça central do subot inteiro é a IA/`subot` comprometida ou adversarial, **sem
root** no host gerenciado — é justamente contra isso que o gate existe (ver seção "Controles de
segurança" do README principal e `packages/subot_core/subot_core/confirm.py`, cujo fluxo de
confirmação em duas etapas, self-servível pela própria IA no mesmo container, foi o motivo de criar
este gate separado). Para essa ameaça específica, `root:root 0600` já é
suficiente e foi validado na prática: `subot` recebe `Permission denied` tentando ler
`telegram.env` ou o próprio `subot-gate-daemon.sh` — a IA não tem como ler o segredo nem reescrever
a lógica de decisão.

**O que um `TELEGRAM_BOT_TOKEN` vazado permite de fato** (menos grave do que parece à primeira
vista): só o token **não** dá poder de aprovar uma escalação. O campo `callback_query.from.id`,
que o daemon confere contra `TELEGRAM_AUTHORIZED_IDS`, é autenticado pelo próprio Telegram no lado
deles — quem só tem o token não consegue forjar um clique como se fosse o humano autorizado. O que
o token vazado realmente habilita:
- ler `getUpdates` a partir de outro lugar e "roubar" atualizações antes do daemon — na pior
  hipótese isso vira negação de serviço da aprovação (a solicitação expira por timeout,
  fail-closed), nunca uma aprovação indevida;
- ler o conteúdo das notificações já enviadas (vazamento de quais comandos foram pedidos e por
  quê);
- mandar mensagens como o bot naquele chat (ruído/engenharia social — não aprovação).

**O que essa permissão de arquivo não protege, e nada baseado só em arquivo local protegeria**:
alguém com **root** no host gerenciado lê `telegram.env` direto, mas se já tem root não precisa do
token pra nada — pode rodar o comando privilegiado sozinho, matar o daemon, ou escrever a resposta
"approved" à mão. Isso é a mesma limitação, já reconhecida no README principal (seção "Controles de
segurança"), da própria chave SSH privada do bastião: "não protege contra alguém com root no host
... limitação de qualquer coisa rodando no mesmo kernel". Um disco/backup roubado do host gerenciado
também expõe o arquivo em texto plano por padrão — igual à observação já feita sobre a passphrase
da chave do bastião nunca entrar em `scripts/backup.sh`.

**Decisão consciente tomada aqui**: não endurecer isso agora com criptografia adicional
(ex.: `systemd-creds` selado em TPM2, que seria o próximo passo natural se o risco de disco/backup
roubado do host gerenciado se tornar relevante) nem com auditoria de leitura (`auditd` watch no
arquivo) — julgado desproporcional ao ganho de segurança neste momento, dado que a ameaça
que o gate existe para mitigar (a IA sem root) já está coberta pela permissão `0600`. Revisitar se
o modelo de ameaça mudar (ex.: hosts gerenciados com backup para local não confiável, ou
preocupação real com comprometimento de root por outra via).

Se o token for suspeito de vazamento: revogue no @BotFather (`/revoke`), gere um novo, atualize
`telegram.env` e reinicie `subot-gate.service` — não existe (ainda) um script de rotação
automatizado equivalente a `scripts/rotate-ssh-keys.sh`.
