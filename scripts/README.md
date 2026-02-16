# Скрипты настройки

Подробное описание скриптов первичной настройки серверов. Общий обзор и быстрый старт — в [главном README](../README.md).

---

## setup-head-ubuntu.sh

Первичная настройка **головной VM на Ubuntu**: пакеты, пользователь с sudo и docker, жёсткая настройка SSH (только ключи, без входа root), fail2ban.

**Требования:** Ubuntu, запуск от root (или sudo). На системе должны быть `wget` или `curl` при загрузке ключа по URL.

### Что делает скрипт (по шагам)

1. **Обновление системы** — `apt-get update` и `upgrade`.
2. **Установка пакетов** — vim, dnsutils, net-tools, iproute2 (в т.ч. `ss`).
3. **sysctl** — отключение IPv6 (`net.ipv6.conf.all/default.disable_ipv6 = 1`) и включение маршрутизации через хост (`net.ipv4.ip_forward = 1`). Файл `/etc/sysctl.d/90-head-vm.conf`.
4. **EDITOR** — прописывает `EDITOR=vim` в `/etc/environment`.
5. **Sudo без пароля** — для группы `%sudo` создаётся `/etc/sudoers.d/90-sudo-nopasswd` (NOPASSWD: ALL), проверка через `visudo -cf`.
6. **Создание пользователя** — имя по переменной `NEW_USER` или случайное из списка (amber, basil, cedar, …). Группы: `sudo`, `docker`. Группа `docker` создаётся, если её ещё нет. Домашний каталог, shell `/bin/bash`.
7. **SSH-ключ** — содержимое публичного ключа добавляется в `~/.ssh/authorized_keys` нового пользователя (права 700/600, владелец — пользователь).
8. **Блокировка root** — `passwd -l root`.
9. **Жёсткая настройка SSH** — drop-in `/etc/ssh/sshd_config.d/90-hardening.conf`:
   - `PermitRootLogin no`
   - `PubkeyAuthentication yes`, `PasswordAuthentication no`, `PermitEmptyPasswords no`
   - `X11Forwarding no`, `AllowAgentForwarding no`, `PermitUserEnvironment no`
   - `MaxAuthTries 3`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`
   - затем `sshd -t` и `systemctl reload sshd`.
10. **fail2ban** — установка, включение jail для sshd: `maxretry=3`, `bantime=1h`, `findtime=10m` (DEFAULT в `jail.local`, sshd в `jail.d/sshd.local`), `systemctl enable --now fail2ban`.
11. **Блок для ~/.ssh/config** — в конце скрипт выводит готовый фрагмент (Host, User, Port, Hostname, IdentityFile). IP или hostname определяется автоматически (сначала публичный IP через ifconfig.me, иначе первый адрес из `hostname -I`). Имя Host и путь к ключу можно задать переменными (см. таблицу).
12. **Опционально: speedtest** — если задана переменная `RUN_SPEEDTEST`, после настройки выполняется `wget -qO- https://speedtest.artydev.ru | bash`.
13. **Опционально: vps-audit** — если задана переменная `RUN_VPS_AUDIT`, скачивается и запускается [vps-audit](https://github.com/vernu/vps-audit) (проверка безопасности VPS).

После выполнения вход по паролю и под root отключён; возможен только вход по ключу под созданным пользователем.

### Запуск

**Через wget (ключ из репо по умолчанию):**

```bash
wget -qO- https://raw.githubusercontent.com/denilai/setup-scripts/master/scripts/setup-head-ubuntu.sh | bash
```

**С указанием ключа (файл или URL):**

```bash
./setup-head-ubuntu.sh /path/to/key.pub
./setup-head-ubuntu.sh https://raw.githubusercontent.com/.../keys/deploy.pub
```

**Ключ переменной окружения:**

```bash
SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." ./setup-head-ubuntu.sh
```

**Форк репо:** задать базовый URL для скачивания скрипта и ключа:

```bash
REPO_RAW_BASE=https://raw.githubusercontent.com/USER/setup-scripts/master wget -qO- "$REPO_RAW_BASE/scripts/setup-head-ubuntu.sh" | bash
```

**С выводом блока для ~/.ssh/config и опциональными проверками** (имя Host, комментарий, speedtest и vps-audit):

```bash
SSH_CONFIG_HOST=eu-vps SSH_CONFIG_COMMENT="xorek.cloud" RUN_SPEEDTEST=1 RUN_VPS_AUDIT=1 ./setup-head-ubuntu.sh keys/deploy.pub
```

### Переменные окружения

| Переменная | Описание |
|------------|----------|
| `NEW_USER` | Имя создаваемого пользователя. Если не задано — случайное из списка (amber, basil, cedar, …). |
| `SSH_PUBLIC_KEY` | Строка с содержимым публичного ключа. Если задана, аргумент и загрузка из репо не используются. |
| `REPO_RAW_BASE` | Базовый URL репо (raw), по умолчанию `https://raw.githubusercontent.com/denilai/setup-scripts/master`. Нужен для загрузки ключа по умолчанию и при запуске через wget. |
| `SKIP_SSH_KEY_CHECK` | Если задана (например `1`), скрипт не выходит с ошибкой при отсутствии ключа (не рекомендуется: можно потерять доступ). |
| `SSH_CONFIG_HOST` | Псевдоним для блока в ~/.ssh/config (строка после `Host`). По умолчанию — значение `NEW_USER`. |
| `SSH_CONFIG_IDENTITY_FILE` | Путь к приватному ключу в выводе (на локальной машине). По умолчанию `~/.ssh/id_ed25519`. |
| `SSH_CONFIG_COMMENT` | Однострочный комментарий над блоком Host (например `xorek.cloud` или `RU-EU tunnel`). |
| `RUN_SPEEDTEST` | Если задана (например `1`), после настройки запускается speedtest с speedtest.artydev.ru. |
| `RUN_VPS_AUDIT` | Если задана (например `1`), после настройки скачивается и запускается vps-audit (vernu/vps-audit). |

### Аргументы

- **Первый аргумент** — путь к файлу с публичным ключом или URL. Игнорируется, если задан `SSH_PUBLIC_KEY`. Если аргумент и переменная не заданы, ключ берётся с `REPO_RAW_BASE/keys/deploy.pub`.

### Важно

- Перед закрытием сессии root убедитесь, что вход по SSH под новым пользователем с вашим ключом работает.
- Без добавленного ключа после перезагрузки sshd вы можете потерять доступ к серверу.

---

## Другие скрипты

Здесь будут описания дополнительных скриптов по мере их появления.
