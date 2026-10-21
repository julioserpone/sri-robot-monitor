# Pruebas

La app se puede probar **sin credenciales de AWS y sin red**. Todo lo que habla
con AWS pasa por `URLSession`, y las pruebas inyectan un `URLProtocol` propio.

## Cómo ejecutar

```bash
# Toda la suite
xcodebuild -project SriRobotMonitor.xcodeproj -scheme SriRobotMonitor \
  -configuration Debug -destination 'platform=macOS' test

# Solo un grupo
xcodebuild -project SriRobotMonitor.xcodeproj -scheme SriRobotMonitor \
  -configuration Debug -destination 'platform=macOS' \
  test -only-testing:SriRobotMonitorTests/AWSClientsTests
```

En Xcode: `⌘U`.

## Qué cubre cada archivo

| Archivo | Qué prueba |
|---|---|
| `CoreLogicTests.swift` | Parser de CloudWatch, `LogAnalyzer` (verde, naranja, rojo, timeout, en curso, obsoleto), periodos, payload y entorno de invocación, `StoredSecrets`, configuración heredada, firma SigV4, decodificador de *event stream*. |
| `AWSClientsTests.swift` | STS, Lambda y CloudWatch contra un `URLProtocol` simulado: firma, cabeceras, parseo de respuestas, traducción de errores, ARN de Live Tail y política de reintentos. |
| `PersistenceTests.swift` | JSON en carpeta temporal, recortes de historial, borrador sin secretos, limpieza selectiva. |
| `ViewSmokeTests.swift` | Construcción de las vistas y `ImageRenderer` sobre cada componente del sistema de diseño. |
| `SnapshotDumpTests.swift` | Genera capturas de las pantallas (opcional, ver abajo). |

## Cómo simular AWS

`StubURLProtocol` intercepta cada petición:

```swift
StubURLProtocol.configure { request in
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Invocation-Type"), "Event")
    return (Self.response(202), Data())
}

let id = try await LambdaClient(
    credentials: credentials,
    region: "us-east-1",
    session: StubURLProtocol.session
).invoke(functionName: "sri-txt-robot", payload: payload)
```

Con eso se prueba, por ejemplo, que una respuesta `403` con
`AccessDeniedException` se convierta en un mensaje que explique los permisos.

## Probar contra AWS de verdad

Si quieres una comprobación real, usa una **cuenta de pruebas** y un usuario IAM
con los permisos mínimos del README:

1. Onboarding con esas credenciales.
2. **Probar credenciales** → debe devolver la cuenta.
3. **Comprobar función** → debe decir `Active`.
4. En Registros, activar *Última ejecución* y relanzar con un mes cerrado.

Casos de borde útiles:

- Clave secreta incorrecta → el asistente debe decir que las credenciales no son
  válidas, no mostrar un JSON de AWS.
- Usuario sin `logs:StartLiveTail` → la app debe seguir actualizando por sondeo
  y decirlo.
- Log group sin streams → "el log group todavía no tiene registros", sin rojo.

## Generar capturas de pantalla

Las capturas automáticas están desactivadas por defecto y se activan con un
archivo centinela:

```bash
touch /tmp/sri-render-snapshots.on
xcodebuild -project SriRobotMonitor.xcodeproj -scheme SriRobotMonitor \
  -configuration Debug -destination 'platform=macOS' \
  test -only-testing:SriRobotMonitorTests/SnapshotDumpTests
rm /tmp/sri-render-snapshots.on
```

Salen en la carpeta temporal del sandbox de la app:

```bash
open ~/Library/Containers/com.julioserpone.sri-robot-monitor/Data/tmp/sri-snapshots
```

> **Aviso**: `ImageRenderer` no dibuja el contenido de un `ScrollView`. Las
> pantallas con scroll (dashboard, ajustes) salen incompletas en las capturas.
> Para validar el aspecto visual, abre la app.

## Lo que las pruebas no cubren

- La consola de AWS real (permisos, cuotas, cuentas sin Live Tail).
- Aspecto visual pixel a pixel. El proyecto es personal; no hay tests de
  regresión visual.
- Firma y notarización del DMG.

## CI

Cada push a `main` y cada PR ejecutan:

1. **Documentación y convenciones** — archivos obligatorios, plantillas,
   ausencia de secretos y de `AKIA…` en el código.
2. **Compilar y probar (macOS)** — build + suite completa sobre `macos-15`.
3. **Análisis de seguridad** — CodeQL para Swift.

Un PR no se fusiona si algún check está en rojo. No hacen falta aprobaciones.
