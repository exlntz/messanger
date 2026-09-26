# Сборка и проверка VOICE для iOS

Документ описывает текущую сборку нативного iOS-приложения VOICE и установку неподписанного IPA.

## Объём приложения

VOICE сейчас включает:

- SwiftUI-приложение для iOS 17+.
- Нативный Liquid Glass на iOS 26+ и SwiftUI fallback на iOS 17-25.
- Без WebKit и WKWebView.
- Регистрацию и вход по email/паролю через Supabase Auth.
- Личные чаты один на один.
- Текст, фото и голосовые сообщения.
- Аудиозвонки через LiveKit.

VOICE сейчас не включает группы, каналы, видеозвонки, ботов, E2EE, push-уведомления, PushKit, сеть Telegram и режим полного клона Telegram.

## Проверено в CI 26 сентября 2026

### iOS unsigned IPA

Финальная проверка iOS build прошла успешно:

- Run: <https://github.com/exlntz/messanger/actions/runs/36226581808>
- Commit: `e7d5caad1c41ec8b28ba9a99ffebefded9426d10`
- Артефакт в браузере: <https://github.com/exlntz/messanger/actions/runs/36226581808/artifacts/10900443439>
- Артефакт: `VOICE-unsigned-ipa`
- `expired=false`
- Размер ZIP: `10182084` bytes, около 10.2 MB
- Внутри: `VOICE-unsigned.ipa`

Сборка и упаковка подтвердили:

- Release build для iOS без подписи.
- Исполняемый файл содержит `arm64`.
- `Info.plist` содержит нужные microphone/background значения.
- Icons asset на месте.
- Platform validation пройдена.
- Упаковка `Payload/VOICE.app` в `VOICE-unsigned.ipa` прошла.

### Другие зелёные проверки

- SQL/backend security: <https://github.com/exlntz/messanger/actions/runs/36226852485>
- Swift model contracts: <https://github.com/exlntz/messanger/actions/runs/36226195529>
- Edge Function typecheck: <https://github.com/exlntz/messanger/actions/runs/36226852506>

Эти проверки не подтверждают запуск на реальном устройстве, вход в удалённый backend или звонок между реальными пользователями.

## Статус IPA

`VOICE-unsigned.ipa` — неподписанный IPA.

Это не готовый подписанный бинарник для прямой установки. Для установки нужна ваша валидная личная подпись:

- через AltStore
- через Sideloadly
- или через платный Apple distribution path

## Backend

Backend-код и инструкции есть в [`docs/BACKEND.md`](BACKEND.md), но backend не развернут.

В репозитории нет готовых endpoint-ов и нет credentials для реального входа.

При первом запуске приложение ожидает:

- `Supabase URL`
- публичный `publishable` или `anon` key Supabase
- `LiveKit URL` в формате `wss://...`

Backend secrets, service role keys и пароли в приложение вводить нельзя.

## Локальная сборка

Требования:

- macOS
- Xcode 26
- Homebrew
- XcodeGen

Команды:

```bash
set -euo pipefail

brew install xcodegen
bash scripts/select_xcode26.sh
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

## Установка через AltStore

1. Установите AltServer на Mac или Windows.
2. Подключите iPhone или iPad.
3. Установите AltStore на устройство.
4. Войдите в AltStore со своим Apple ID.
5. Возьмите `VOICE-unsigned.ipa` из локальной сборки или из артефакта успешного GitHub Actions run.
6. Откройте IPA через AltStore и подпишите его.

## Установка через Sideloadly

1. Установите Sideloadly.
2. Подключите iPhone или iPad.
3. Перетащите `VOICE-unsigned.ipa` в окно Sideloadly.
4. Введите свой Apple ID.
5. Запустите подпись и установку.

Для бесплатного Apple ID подпись обычно живёт ограниченное время. Это не production-доставка.

## Ограничения текущей сборки

### Звонки

- Входящие звонки работают только в foreground.
- PushKit не реализован.
- Push-уведомлений нет.
- Активный звонок использует `audio` background mode, но работа в фоне на реальном устройстве не подтверждена.

### Сообщения и данные

- Чат запрашивает последние 500 сообщений.
- История звонков запрашивает последние 100 записей.
- Поиск людей требует минимум 2 символа и даёт максимум 30 результатов.
- Текст ограничен 4000 символами.
- Голосовое сообщение ограничено 5 минутами.
- Медиа в чат ограничены 15 MB.
- Аватар ограничен 5 MB.
- Приложение не offline-first.
- Долговечной очереди отправки нет.
- Автоматической гарантированной дозагрузки и ретрая неотправленных сообщений нет.

### Безопасность

- Токены сеанса хранятся в Keychain.
- Пароль не сохраняется.
- В конфигурацию приложения принимаются только публичные ключи Supabase.
- Секреты LiveKit и backend не должны попадать в приложение или репозиторий.
- E2EE не реализован и не должен заявляться.

## Ручной тест перед заявлением о runtime-готовности

Реальные устройства и удалённая backend-интеграция пока не тестировались.

Минимальный ручной тест нужен на двух реальных пользователях и двух реальных устройствах:

1. Поднять backend по [`docs/BACKEND.md`](BACKEND.md).
2. Подготовить рабочие Supabase URL, публичный Supabase key и LiveKit WSS URL.
3. Подписать и установить IPA на два устройства.
4. Зарегистрировать или войти в два разных аккаунта.
5. Проверить поиск пользователя.
6. Проверить отправку текста.
7. Проверить отправку фото.
8. Проверить запись и отправку голосового сообщения.
9. Проверить исходящий звонок.
10. Проверить принятие звонка.
11. Проверить отклонение звонка.
12. Проверить mute и unmute.
13. Проверить завершение звонка с обеих сторон.
14. Проверить переподключение при временной потере сети.
15. Проверить отказ в доступе к микрофону.
16. Проверить logout.

Пока этот сценарий не пройден, не заявляйте полную runtime-готовность.
