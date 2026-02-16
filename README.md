# setup-scripts

Скрипты первичной настройки серверов (Ubuntu).

## Содержимое

- **scripts/** — скрипты настройки. Подробное описание: [scripts/README.md](scripts/README.md).
- **keys/** — публичные SSH-ключи для деплоя. Как добавить свой ключ: [keys/README.md](keys/README.md).

## Быстрый старт: головная VM (Ubuntu)

1. Один раз добавьте публичный SSH-ключ в репо: файл `keys/deploy.pub` (см. [keys/README.md](keys/README.md)).
2. На чистом сервере залогиньтесь под **root**, затем:
   ```bash
   wget -qO- https://raw.githubusercontent.com/denilai/setup-scripts/master/scripts/setup-head-ubuntu.sh | bash
   ```
3. Проверьте вход с вашей машины под новым пользователем по SSH-ключу (имя скрипт выведет в конце). После этого можно закрывать сессию root.

Подробности (переменные, альтернативный запуск через clone, форк): [scripts/README.md](scripts/README.md).
