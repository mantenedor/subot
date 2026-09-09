# secrets/ssh

Este diretório nunca é versionado (veja `.gitignore`) — contém material criptográfico real.

- `bastion_id_ed25519` / `bastion_id_ed25519.pub` — par de chaves do próprio bastião, gerado por
  `scripts/setup.sh`. A chave privada deveria ter permissão `600`; por padrão o subot apenas
  **avisa** se estiver mais permissiva (não bloqueia), porque bind mounts a partir de um host
  Windows via Docker Desktop nem sempre preservam permissões POSIX com precisão. Defina
  `SUBOT_STRICT_KEY_PERMS=true` em `.env` depois de validar que `chmod 600` é respeitado no seu
  ambiente (ex.: WSL2) para transformar o aviso em bloqueio de fato.

  **A chave é gerada já protegida por passphrase** (AES, formato nativo do OpenSSH) — o arquivo
  em disco nunca é texto plano utilizável sozinho. A passphrase é gerada por `scripts/setup.sh`,
  mostrada **uma única vez** no terminal e **nunca é salva em nenhum arquivo**. Pra subir a stack:

  ```bash
  export SUBOT_SSH_KEY_PASSPHRASE='a-passphrase-que-o-setup.sh-mostrou'
  docker compose up -d
  ```

  Sem essa variável no ambiente do processo `docker compose up`, os containers sobem mas toda
  operação SSH falha (os entrypoints avisam isso). Se colocar a passphrase em `.env` por
  conveniência (reinício automático sem alguém digitar de novo), ela volta a morar no mesmo disco
  que a chave — reduz a proteção real a "alguém precisa ler dois arquivos em vez de um", ainda
  assim melhor que nada, mas é uma escolha consciente, não o padrão.

  Só precisa reexportar a passphrase quando o container é **recriado** (`docker compose down && up`,
  `--force-recreate`, instalação nova) — um reboot simples da VM reaproveita a configuração que já
  estava gravada no container e não pede nada.

  **A passphrase nunca entra em `scripts/backup.sh`.** Guarde-a em um gerenciador de senhas ou
  cofre da organização assim que ela aparecer — sem isso, restaurar o backup numa VM nova devolve
  a chave cifrada sem nenhuma forma de abri-la (perda permanente; só resolve gerando uma chave
  nova e redistribuindo a pública pra todos os hosts).
- `known_hosts` — populado manualmente (ou via a skill `onboard-host`) com a fingerprint real de
  cada host gerenciado. O subot usa `paramiko.RejectPolicy`: nunca aceita uma host key
  desconhecida automaticamente.
- Chaves por-host opcionais podem ser adicionadas aqui e referenciadas pelo campo
  `identity_file` de cada host em `config/hosts.yaml`.

Para rotacionar, use `scripts/rotate-ssh-keys.sh` (ou a skill `key-rotation`) — nunca edite chaves
manualmente nem as apague antes de validar que os hosts aceitam a nova.
