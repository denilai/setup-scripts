# Скрипты настройки

Подробное описание скриптов первичной настройки серверов. Общий обзор и быстрый старт — в [главном README](../README.md).

---

## setup-head-ubuntu.sh

Первичная настройка **головной VM на Ubuntu**: пакеты, пользователь с sudo и docker, жёсткая настройка SSH (только ключи, без входа root), fail2ban.

**Требования:** Ubuntu, запуск от root (или sudo). На системе должны быть `wget` или `curl` при загрузке ключа по URL.

### Что делает скрипт (по шагам)

1. **Обновление системы** — `apt-get update` и `upgrade`.
2. **Установка пакетов** — vim, dnsutils, net-tools, iproute2 (в т.ч. `ss`).
3. **EDITOR** — прописывает `EDITOR=vim` в `/etc/environment`.
4. **Sudo без пароля** — для группы `%sudo` создаётся `/etc/sudoers.d/90-sudo-nopasswd` (NOPASSWD: ALL), проверка через `visudo -cf`.
5. **Создание пользователя** — имя по переменной `NEW_USER` или случайное из списка (amber, basil, cedar, …). Группы: `sudo`, `docker`. Группа `docker` создаётся, если её ещё нет. Домашний каталог, shell `/bin/bash`.
6. **SSH-ключ** — содержимое публичного ключа добавляется в `~/.ssh/authorized_keys` нового пользователя (права 700/600, владелец — пользователь).
7. **Блокировка root** — `passwd -l root`.
8. **Жёсткая настройка SSH** — drop-in `/etc/ssh/sshd_config.d/90-hardening.conf`:
   - `PermitRootLogin no`
   - `PubkeyAuthentication yes`, `PasswordAuthentication no`, `PermitEmptyPasswords no`
   - `X11Forwarding no`, `AllowAgentForwarding no`, `PermitUserEnvironment no`
   - `MaxAuthTries 3`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`
   - затем `sshd -t` и `systemctl reload sshd`.
9. **fail2ban** — установка, включение jail для sshd: `maxretry=3`, `bantime=1h`, `findtime=10m` (DEFAULT в `jail.local`, sshd в `jail.d/sshd.local`), `systemctl enable --now fail2ban`.

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

### Переменные окружения

| Переменная | Описание |
|------------|----------|
| `NEW_USER` | Имя создаваемого пользователя. Если не задано — случайное из списка (amber, basil, cedar, …). |
| `SSH_PUBLIC_KEY` | Строка с содержимым публичного ключа. Если задана, аргумент и загрузка из репо не используются. |
| `REPO_RAW_BASE` | Базовый URL репо (raw), по умолчанию `https://raw.githubusercontent.com/denilai/setup-scripts/master`. Нужен для загрузки ключа по умолчанию и при запуске через wget. |
| `SKIP_SSH_KEY_CHECK` | Если задана (например `1`), скрипт не выходит с ошибкой при отсутствии ключа (не рекомендуется: можно потерять доступ). |

### Аргументы

- **Первый аргумент** — путь к файлу с публичным ключом или URL. Игнорируется, если задан `SSH_PUBLIC_KEY`. Если аргумент и переменная не заданы, ключ берётся с `REPO_RAW_BASE/keys/deploy.pub`.

### Важно

- Перед закрытием сессии root убедитесь, что вход по SSH под новым пользователем с вашим ключом работает.
- Без добавленного ключа после перезагрузки sshd вы можете потерять доступ к серверу.

---

## Другие скрипты

Здесь будут описания дополнительных скриптов по мере их появления.
