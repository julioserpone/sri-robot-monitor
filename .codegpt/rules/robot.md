# Comportamiento del robot
# ---
# Reglas para quien contribuya a este repositorio con asistencia de IA
# o herramientas automáticas. El proyecto también las usa para revisarse.

## Alcance
paths: ["SriRobotMonitor/**", "Tests/**", ".github/**", "docs/**"]
description: >
  Código de la app macOS y su automatización. Las reglas de abajo aplican a
  cambios propuestos por personas o por asistentes de IA.

## Prohibido
- Incluir credenciales reales de AWS, tokens, claves del portal del SRI,
  claves de anti-captcha o el RUC de contribuyentes en código, pruebas,
  ejemplos, mensajes de commit o issues.
- Añadir dependencias externas sin discutirlo antes en un issue: el proyecto
  es deliberadamente autocontenido (SwiftUI + Foundation + CryptoKit).
- Escribir logs de la app que contengan secretos, incluso a nivel `debug`.
- Cambiar los permisos de AWS que se le piden al usuario sin actualizar
  README.md, SECURITY.md y el onboarding en el mismo PR.
- Usar `try!`, `fatalError` o `as!` en rutas que dependen de datos de AWS.

## Obligatorio
- Las pruebas pasan: `xcodebuild ... test`.
- Todo cambio visible se anota en `CHANGELOG.md`, sección `No publicar`.
- Los comentarios explican el **por qué**, en español.
- Si tocas la firma SigV4 o el decodificador de streams, añade una prueba que
  falle sin tu cambio.
- Si usas IA, decláralo en la sección correspondiente del PR y di qué no
  pudiste verificar.

## Convenciones
- Ramas: `feat/`, `fix/`, `docs/`, `chore/`, `test/`.
- Commits: Conventional Commits, en español el cuerpo, en inglés el tipo.
- Swift 6 con `@MainActor` y `Sendable` explícitos; estructura hereda `@Observable`.
