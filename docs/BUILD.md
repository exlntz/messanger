# Сборка и проверка VOICE для iOS

Этот документ описывает только текущее состояние iOS-приложения VOICE и путь к неподписанному IPA.

## Что это за приложение

VOICE сейчас это:

- нативное SwiftUI-приложение для iOS 17+
- Liquid Glass на iOS 26+, обычный SwiftUI fallback на iOS 17-25
- без WebKit и без WKWebView
- регистрация и вход по email/паролю через Supabase Auth
- личные чаты один на один
- текст, фото, голосовые сообщения
- аудиозвонки через LiveKit

VOICE сейчас не включает:

- группы
- каналы
- видеозвонки
- ботов
- E2EE
- push-уведомления
- PushKit
- интеграцию с сетью Telegram
- режим полного клона Telegram

## Что есть в репозитории

- iOS-код: `ios/VOICE`
- проект XcodeGen: `project.yml`
- workflow сборки iOS: `.github/workflows/ios.yml`
- скрипт упаковки IPA: `scripts/package_unsigned_ipa.sh`
- backend-код и инструкции: [`docs/BACKEND.md`](BACKEND.md)

Backend-код в репозитории есть, но он не развернут. В репозитории нет готовых endpoint-ов и нет credentials для реального входа.

## Что приложение реально ожидает при первом запуске

Экран настройки просит ввести:

- `Supabase URL`
- публичный `publishable` или `anon` key Supabase
- `LiveKit URL` в формате `wss://...`

Секреты backend, service role keys и пароли в приложение вводить нельзя.

## Текущее состояние GitHub Actions

Есть два workflow:

- [`iOS unsigned IPA`](../.github/workflows/ios.yml)
- [`Backend Security`](../.github/workflows/backend.yml)

На момент обновления этих документов:

- последний успешный run на `main` есть у Backend Security
- последние run iOS workflow на `main` не подтверждают готовый проверенный IPA

Проверяйте текущий статус здесь:

- <https://github.com/exlntz/messanger/actions>
- <https://github.com/exlntz/messanger/actions/workflows/ios.yml>
- <https://github.com/exlntz/messanger/actions/workflows/backend.yml>

Не заявляйте, что сборка green или что IPA проверен, пока конкретный run iOS workflow не завершился успехом.

## Что делает iOS workflow

Workflow `.github/workflows/ios.yml` запускается на `push` в `main` для изменений в iOS-части и вручную через `workflow_dispatch`.

Он делает следующее:

1. выбирает Xcode 26
2. ставит XcodeGen
3. генерирует иконку и `VOICE.xcodeproj`
4. резолвит Swift packages
5. собирает Release для `generic/platform=iOS` без подписи
6. проверяет, что бинарь `VOICE.app` содержит `arm64`
7. пакует `Payload/VOICE.app` в `VOICE-unsigned.ipa`
8. загружает артефакт `VOICE-unsigned-ipa`
9. загружает диагностические логи сборки

Если workflow завершится успешно, артефакт `VOICE-unsigned-ipa` будет доступен в карточке успешного run в GitHub Actions. Внутри будет файл `VOICE-unsigned.ipa`.

## Важный статус артефакта

`VOICE-unsigned.ipa` это неподписанный IPA.

Это не готовый подписанный бинарник для прямой установки. Его надо подписать своей валидной личной подписью:

- через AltStore
- через Sideloadly
- или через платный Apple distribution path

Если iOS workflow не завершился успехом, не считайте этот IPA подтверждённым.

## Локальная сборка

Требования:

- macOS
- Xcode 26
- Homebrew
- XcodeGen

Команды:

```bash
brew install xcodegen
sudo xcode-select -s "$(find /Applications -maxdepth 1 \( -type d -o -type l \) -name 'Xcode_26*.app' | sort | tail -n 1)/Contents/Developer"
python3 scripts/generate_app_icon.py
xcodegen generate --spec project.yml
xcodebuild -resolvePackageDependencies -project VOICE.xcodeproj -scheme VOICE
xcodebuild \
  -project VOICE.xcodeproj \
  -scheme VOICE \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build | tee build.log
bash scripts/package_unsigned_ipa.sh
```

При успешной локальной упаковке файл будет здесь:

```text
VOICE-unsigned.ipa
```

## Установка

### AltStore

1. Установите AltServer на Mac или Windows.
2. Подключите iPhone или iPad.
3. Установите AltStore на устройство.
4. Войдите в AltStore со своим Apple ID.
5. Возьмите `VOICE-unsigned.ipa` из локальной сборки или из артефакта успешного GitHub Actions run.
6. Откройте IPA через AltStore и подпишите его.

### Sideloadly

1. Установите Sideloadly.
2. Подключите iPhone или iPad.
3. Перетащите `VOICE-unsigned.ipa` в окно Sideloadly.
4. Введите свой Apple ID.
5. Запустите подпись и установку.

Для бесплатного Apple ID подпись обычно живёт ограниченное время. Это не постоянная production-доставка.

## Ограничения текущей сборки

### Связь и звонки

- входящие звонки работают только в foreground
- PushKit не реализован
- push-уведомлений нет
- активный звонок использует `audio` background mode, но работа в фоне на реальном устройстве не подтверждена

### Сообщения и данные

- в чате запрашиваются только последние 500 сообщений
- история звонков запрашивает только последние 100 записей
- поиск людей требует минимум 2 символа и даёт максимум 30 результатов
- текст ограничен 4000 символами
- голосовое сообщение ограничено 5 минутами
- медиа в чат ограничены 15 МБ
- аватар ограничен 5 МБ
- приложение не offline-first
- durable outbox нет
- автоматической гарантированной дозагрузки и ретрая неотправленных сообщений нет

### Безопасность и хранение

- токены сеанса хранятся в Keychain
- пароль не сохраняется
- в конфигурацию приложения принимаются только публичные ключи Supabase
- секреты LiveKit и backend не должны попадать в приложение или репозиторий
- E2EE не реализован и не должен заявляться

## Ручной тест перед любыми заявлениями о готовности

Не заявляйте, что приложение полностью работает, пока не выполнен ручной тест на 2 реальных пользователях и 2 реальных устройствах.

Минимальный сценарий:

1. Поднимите сервер по [`docs/BACKEND.md`](BACKEND.md).
2. Подготовьте рабочие Supabase URL, публичный ключ и LiveKit WSS URL.
3. Подпишите и установите IPA на 2 устройства.
4. Зарегистрируйте или войдите в 2 разных аккаунта.
5. Проверьте поиск пользователя.
6. Проверьте отправку текста.
7. Проверьте отправку фото.
8. Проверьте запись и отправку голосового сообщения.
9. Проверьте исходящий звонок.
10. Проверьте принятие звонка.
11. Проверьте отклонение звонка.
12. Проверьте mute и unmute.
13. Проверьте завершение звонка с обеих сторон.
14. Проверьте переподключение при временной потере сети.
15. Проверьте отказ в доступе к микрофону.
16. Проверьте logout.

Пока этот сценарий не пройден, не говорите, что рантайм полностью подтверждён.

## Что реально подтверждают CI сейчас

Backend workflow проверяет локальные SQL migration и security-тесты.

iOS workflow пытается:

- сгенерировать Xcode project
- собрать Release без подписи
- упаковать неподписанный IPA
- приложить логи

CI сам по себе не подтверждает:

- успешный вход в реальные сервисы
- обмен сообщениями между двумя реальными пользователями
- работу фото и голосовых сообщений на реальных устройствах
- стабильную работу аудиозвонка на реальных устройствах
- работу в фоне
- install-ready signed binary
