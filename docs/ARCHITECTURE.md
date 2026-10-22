# Arquitectura

## Resumen

```
┌───────────────────────────────────────────────────────────────┐
│  SwiftUI (Liquid Glass)                                       │
│  Onboarding · Dashboard · Runs · Logs · Settings · MenuBar    │
└───────────────────────────────┬───────────────────────────────┘
                                │ @Observable, @MainActor
┌───────────────────────────────┴───────────────────────────────┐
│  MonitorEngine                                                │
│  estado · sondeo · Live Tail · notificaciones · invocación    │
└───────┬───────────────────┬───────────────────────┬───────────┘
        │                   │                       │
┌───────┴────────┐  ┌───────┴────────┐     ┌────────┴─────────┐
│  AppPersistence│  │ AwS clients    │     │ LogAnalyzer      │
│  JSON + Llavero│  │ SigV4 a mano   │     │ runs desde logs  │
└────────────────┘  └───────┬────────┘     └──────────────────┘
                            │ HTTPS
                   STS · Lambda · CloudWatch Logs
```

## Capas

### `SriRobotMonitor/AWS/`

Cliente HTTP propio, **sin el SDK de AWS**. Es una decisión deliberada:

- La app es de escritorio y solo usa cinco operaciones.
- El SDK añadiría decenas de MB y su ciclo de vida al proyecto.
- La firma SigV4 cabe en 150 líneas y se puede probar de forma determinista.

| Archivo | Responsabilidad |
|---|---|
| `AWSClient` | Petición firmada, lectura de respuesta, traducción de errores. |
| `AWSSigner` | Signature Version 4 (`AWS4-HMAC-SHA256`). |
| `AWSEventStreamDecoder` | Decodificador binario del *event stream* de AWS. |
| `STSClient` | `GetCallerIdentity` (validar credenciales). |
| `LambdaClient` | Configuración, variables de entorno, `Event` y `RequestResponse`. |
| `CloudWatchLogsClient` | `FilterLogEvents` y `StartLiveTail`. |

### `SriRobotMonitor/Services/`

- **`MonitorEngine`** — `@MainActor @Observable`. Es la única fuente de verdad:
  credenciales, configuración, ejecuciones, logs, errores y estado del LED.
  Mantiene dos tareas: el sondeo (respaldo) y el Live Tail (principal).
- **`LogAnalyzer`** — reconstruye ejecuciones a partir de líneas de CloudWatch
  mezcladas. Agrupa por `RequestId`, cuenta descargas, claves y fallos, y decide
  el color del LED.
- **`CloudWatchLogParser`** — normaliza JSON estructurado y texto plano.
- **`AppPersistence`** — JSON en `Application Support`; ejecuciones y logs con
  recorte para no crecer sin límite.
- **`KeychainStore`** — credenciales y claves del robot en el Llavero.
- **`NotificationService`** — avisos de macOS.

### `SriRobotMonitor/Views/`

SwiftUI con el sistema de diseño de `DesignSystem.swift`: `GlassCard`,
`StatusLED`, `StatusOrb`, `MetricTile`, `ToastBanner`. Todo el estado llega por
`@Environment(MonitorEngine.self)`; las vistas no llaman a AWS.

## Flujos

### Arranque

```
RootView → engine.bootstrap()
  ├─ carga configuracion.json
  ├─ carga credenciales y claves del Llavero
  ├─ carga ejecuciones y logs
  └─ si hay credenciales → startMonitoring()
        ├─ startLiveTail()   ← principal
        └─ pollTask          ← respaldo
```

### Lectura de logs

1. **Live Tail** abre `StartLiveTail` sobre `stream-logs.<región>.amazonaws.com`
   con el ARN del log group.
2. Cada `sessionUpdate` trae líneas que se deduplican por un `eventId`
   construido (stream + timestamp + hash del mensaje).
3. **Sondeo** cada `pollIntervalSeconds` con `FilterLogEvents`:
   - con Live Tail activo, baja a 30 s (solo cubre huecos);
   - sin Live Tail, cubre la ventana completa.
4. Ambos alimentan `merge(events:)`, que recalcula ejecuciones, estado y avisos.

### Relanzar el robot

| Modo | Lambda | Qué muestra |
|---|---|---|
| `Event` (por defecto) | Responde con `RequestId` en cuanto se acepta. | Progreso por Live Tail. |
| `RequestResponse` (*Esperar el resultado*) | Espera al `REPORT`. | Resumen con descargas, claves y fallos. |

Con *Esperar el resultado* se pueden adjuntar las claves del robot en el campo
`environment` del evento. Es la única forma de enviar secretos sin
`lambda:UpdateFunctionConfiguration`, que la app no pide. El timeout del cliente
es de 910 s: Lambda corta a los 900 s.

## Estado

`RobotStatus` es un enum con cinco casos y lo consume toda la UI:

| Caso | LED | Cuándo |
|---|---|---|
| `.healthy` | verde | Terminó con resumen y sin fallos ni warnings. |
| `.warning` | naranja | Terminó bien pero con warnings. |
| `.error` | rojo | Fallos, timeout, sin resumen o la app no puede leer AWS. |
| `.running` | azul, pulsante | Hay una ejecución en curso. |
| `.unknown` | gris | Aún sin datos. |

`MonitorEngine.effectiveStatus` combina el resultado de la última ejecución con
el estado de la propia supervisión: si no se puede leer CloudWatch, el LED no
puede afirmar que el robot esté operativo.

## Persistencia

| Datos | Dónde | Formato |
|---|---|---|
| Preferencias y alcance (región, función, log group) | `configuracion.json` | JSON |
| Últimas 100 ejecuciones | `ejecuciones.json` | JSON |
| Últimos 2 000 logs | `registros.json` | JSON |
| Avisos ya enviados | `notificadas.json` | JSON |
| Borrador del onboarding (sin secretos) | `onboarding.json` | JSON |
| Credenciales AWS y claves del robot | Llavero | `StoredSecrets` |

## Decisiones y sus motivos

- **Sin SDK de AWS.** Menos peso, menos superficie de ataque y control total de
  la firma y del stream.
- **Live Tail con respaldo.** Live Tail solo llega a cuentas y permisos que lo
  admiten; el sondeo garantiza que la app nunca se quede muda. Cuando la API
  devuelve un error permanente, se deja de reintentar y se informa en pantalla.
- **Claves del robot en el evento.** Rotar una clave no exige tocar la función
  ni desplegar nada.
- **Un solo archivo de Llavero.** Un restablecimiento no deja secretos
  huérfanos.
- **Todo en `@MainActor`.** El estado es pequeño; la E/S ocurre fuera.

## Limitaciones conocidas

- La build pública no está notarizada.
- `ImageRenderer` no dibuja el interior de `ScrollView`, así que las capturas
  automáticas de pantallas con scroll salen incompletas (la app real no se ve
  afectada).
- El modo `RequestResponse` ocupa una conexión durante toda la ejecución: no
  está pensado para lanzar diez robots en paralelo desde la app.
