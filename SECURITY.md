# Política de seguridad

## Versiones soportadas

Solo la última versión publicada recibe correcciones de seguridad.

| Versión | Soporte |
|---|---|
| 1.1.x | ✅ |
| < 1.1 | ❌ |

## Cómo reportar una vulnerabilidad

**No abras un issue público.** Usa el reporte privado de GitHub:

1. Ve a la pestaña **Security** del repositorio.
2. Elige **Report a vulnerability**.

Incluye:

- Versión de la app y de macOS.
- Pasos para reproducirlo.
- Impacto que crees que tiene (por ejemplo: "las claves de AWS quedan legibles
  en un log").
- Si lo deseas, una propuesta de arreglo.

Respondemos en un plazo orientativo de **72 horas** y coordinamos contigo la
divulgación.

## Modelo de amenazas

La app guarda secretos reales, así que conviene ser explícito con lo que
protege y lo que no.

### Qué protege

- **Credenciales en el Llavero.** Las claves de AWS y las claves del robot
  (`SRI_PASSWORD`, `ANTICAPTCHA_API_KEY`) viven en una entrada
  `kSecClassGenericPassword` ligada a la app, con
  `kSecAttrAccessibleAfterFirstUnlock`. No se escriben en ningún JSON.
- **Sandbox de macOS.** La app está *sandboxed*: solo escribe en su contenedor
  (`~/Library/Containers/com.julioserpone.sri-robot-monitor/Data`).
- **Sin telemetría.** No hay analítica ni envío de datos a terceros.
- **Firma SigV4 en el cliente.** Las claves nunca salen del equipo: se usan
  para firmar peticiones HTTPS a AWS y no se envían como cabecera.
- **Secretos fuera de los logs.** El borrador del onboarding se guarda sin
  secretos y las claves no aparecen en los registros de la app.

### Qué no protege

- Un proceso con los mismos permisos de usuario que pueda leer el Llavero
  desbloqueado o inyectar código en la app.
- Credenciales pegadas en otro sitio (notas, capturas de pantalla, la consola de
  AWS).
- **Modo `tail` en tránsito**: las claves del robot viajan en el cuerpo del
  evento de invocación. Va cifrado en tránsito por TLS y no se guarda en los
  logs de Lambda, pero **sí** aparece en las trazas de invocación de AWS
  (CloudTrail guarda el evento, no el cuerpo). Si te preocupa ese rastro, usa
  las variables de entorno de la función en su lugar.
- La build pública **no está notarizada**: macOS pedirá confirmación manual la
  primera vez.

## Recomendaciones de despliegue

- Usa un usuario IAM dedicado, con los permisos mínimos de
  [README.md](README.md#requisitos). Nada de claves root.
- Si puedes, usa credenciales temporales (con `session token`) y rota las claves
  periódicamente. La app tiene un botón de revalidación para ese caso.
- Revisa los permisos de la función de Lambda: la app solo necesita invocarla,
  leer su configuración y leer su log group.

## Dependencias

El proyecto no usa dependencias de terceros. Las acciones de GitHub están
fijadas a *major* y **Dependabot** propone actualizaciones semanales.
