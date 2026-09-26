# VOICE

VOICE — независимый нативный iOS-мессенджер на SwiftUI для iOS 17+.

Это не Telegram-клиент, не сеть Telegram и не полный клон Telegram.

## Что есть

- SwiftUI, без WebKit и WKWebView.
- Liquid Glass на iOS 26+, обычный SwiftUI fallback на iOS 17-25.
- Регистрация и вход по email/паролю через Supabase Auth.
- Личные чаты один на один.
- Текст, фото и голосовые сообщения.
- Аудиозвонки через LiveKit.
- Токены сеанса хранятся в Keychain.
- В приложение вводятся только публичные ключи Supabase `publishable` или `anon`.

## Чего нет

Нет групп, каналов, видеозвонков, ботов, E2EE, push-уведомлений, PushKit и фонового приёма входящих звонков.

## Проверено 26 сентября 2026

- iOS build PASS: <https://github.com/exlntz/messanger/actions/runs/36226581808>
- Commit: `e7d5caad1c41ec8b28ba9a99ffebefded9426d10`
- Артефакт: <https://github.com/exlntz/messanger/actions/runs/36226581808/artifacts/10900443439>
- Артефакт `VOICE-unsigned-ipa` не expired, размер ZIP около 10.2 MB, внутри `VOICE-unsigned.ipa`.
- Упаковка прошла проверки arm64, Info.plist, microphone/background keys, icons asset и iOS platform.

Дополнительные зелёные проверки:

- SQL: <https://github.com/exlntz/messanger/actions/runs/36226852485>
- Swift Models: <https://github.com/exlntz/messanger/actions/runs/36226195529>
- Edge typecheck: <https://github.com/exlntz/messanger/actions/runs/36226852506>

## Важно про IPA

`VOICE-unsigned.ipa` — неподписанная сборка. Это не готовый подписанный бинарник для прямой установки.

Для установки нужна ваша валидная личная подпись через AltStore, Sideloadly или платный Apple distribution path.

## Backend

Код backend есть в репозитории, но backend не развернут. В репозитории нет готовых endpoint-ов и credentials.

Для реального запуска поднимите сервер по [`docs/BACKEND.md`](docs/BACKEND.md), затем введите в приложении Supabase URL, публичный Supabase key и LiveKit WSS URL.

## Ограничения

- Реальные устройства и удалённая backend-интеграция не тестировались.
- Входящий звонок показывается только когда приложение открыто и активно.
- Background audio capability для активного звонка на устройстве не подтверждён.
- Чат загружает последние 500 сообщений.
- История звонков загружает последние 100 записей.
- Поиск людей требует минимум 2 символа и возвращает до 30 результатов.
- Текст: до 4000 символов.
- Голосовое сообщение: до 5 минут.
- Медиа в чат: до 15 MB. Аватар: до 5 MB.
- Приложение не offline-first. Долговечной очереди отправки нет.

Не заявляйте полную runtime-готовность, пока не пройдён ручной тест на двух реальных пользователях и двух реальных устройствах.
