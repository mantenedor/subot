---
name: onboard-host
description: Adiciona um novo host ao inventário do subot (config/hosts.yaml), opcionalmente cria uma conexão no Guacamole e popula o known_hosts. Use quando o pedido for para adicionar/registrar um novo servidor a ser gerenciado.
---

# onboard-host

1. Reúna: nome lógico, endereço, porta, usuário, protocolo (`ssh`/`rdp`/`vnc`), grupos e tags
   (marque `protected`/`prod` se aplicável).
2. Chame `mcp__inventory_connector__add_host` — isso sempre exige confirmação (é uma ação
   sensível: altera o que o subot tem permissão de alcançar).
3. Para hosts SSH: popule `./secrets/ssh/known_hosts` com a host key real antes do primeiro
   `ssh_exec` (fora de banda, verificando a fingerprint por um canal confiável — nunca aceite
   automaticamente).
4. Para hosts RDP/VNC: use `mcp__remote_desktop_connector__open_desktop_session` para criar a
   conexão no Guacamole na primeira vez.
5. Confirme o onboarding com um comando trivial e somente-leitura antes de considerar o host
   pronto para uso.
