# setup-scripts

Скрипты первичной настройки серверов (Ubuntu).

## Первичная настройка головной VM (Ubuntu)

Скрипт ставит пакеты, создаёт пользователя с sudo и docker, настраивает SSH (только ключи, без root), fail2ban и т.д.

### Подготовка (один раз)

1. **Добавьте публичный SSH-ключ в репозиторий**  
   Создайте файл `keys/deploy.pub` с одной строкой — содержимым вашего `~/.ssh/id_ed25519.pub`.  
   Подробнее: [keys/README.md](keys/README.md).

### Запуск на чистом сервере

Залогиньтесь под **root** (по паролю), затем выполните:

```bash
wget -qO- https://raw.githubusercontent.com/denilai/setup-scripts/master/scripts/setup-head-ubuntu.sh | bash
```

Ключ по умолчанию берётся из этого репо (`keys/deploy.pub`). На минимальном Ubuntu обычно уже есть `wget`; если нет — сначала: `apt-get update && apt-get install -y wget`.

Если используете форк репо, задайте базовый URL:  
`REPO_RAW_BASE=https://raw.githubusercontent.com/USER/setup-scripts/master wget -qO- .../setup-head-ubuntu.sh | bash`

**Вариант через clone** (если удобнее клонировать репо):

```bash
apt-get update && apt-get install -y git
git clone https://github.com/denilai/setup-scripts.git
cd setup-scripts
./scripts/setup-head-ubuntu.sh keys/deploy.pub
```

После выполнения зайдите с вашей машины под новым пользователем по SSH-ключу (имя пользователя скрипт выведет в конце, например `amber` или `sage`). Убедитесь, что вход работает, прежде чем закрывать сессию root.

### Переменные

- `NEW_USER=myadmin` — задать имя пользователя вместо случайного.
- Ключ: по умолчанию скачивается из репо (`REPO_RAW_BASE/keys/deploy.pub`). Переопределить: первый аргумент (путь или URL) или переменная `SSH_PUBLIC_KEY`, или `REPO_RAW_BASE` для другого репо.
