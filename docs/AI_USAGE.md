# Uso de IA en este proyecto

Este proyecto se construyó **en pareja con un asistente de IA** (un agente de
código basado en un modelo de lenguaje, ejecutado dentro del editor). Este
documento explica cómo, con qué límites y qué se hizo para que el resultado sea
confiable. No es una declaración de intenciones: describe lo que realmente se
hizo.

## Qué hizo la IA

- **Explorar** el repositorio `sri-txt-robot` para alinear el payload, los
  nombres de variables (`SRI_PASSWORD`, `ANTICAPTCHA_API_KEY`) y el formato de
  los logs estructurados.
- **Escribir** la primera versión de la mayoría de archivos: cliente SigV4,
  decodificador del *event stream*, `MonitorEngine`, vistas, pruebas, workflows
  y esta documentación.
- **Iterar** sobre errores de compilación y de pruebas hasta dejarlos en verde.
- **Revisar** el propio código: detectó que el decodificador no consumía el
  separador `\r\n\r\n` entre mensajes del *event stream*.

## Qué hizo la persona

- Definió el alcance, la experiencia deseada ("parecida a Laravel Herd"),
  el modelo de permisos y la forma de publicar.
- Decidió las reglas del repositorio: `main` protegida, sin aprobaciones, checks
  obligatorios.
- Verificó el comportamiento real en AWS y validó la UI.
- Revisó y aprobó cada cambio antes de integrarlo.

## Reglas que se siguieron

1. **Nada se declara terminado sin evidencia.** Cada afirmación del resumen
   final se apoya en un `xcodebuild` o en una salida real. Cuando no se pudo
   verificar algo (por ejemplo, el aspecto visual con la pantalla bloqueada), se
   dijo explícitamente.
2. **Los errores de la IA se corrigen en el código, no en la prueba.** Si una
   prueba fallaba por un defecto real, se arreglaba el defecto. Solo se ajustó
   la prueba cuando el fallo era del propio fixture.
3. **Sin secretos ni datos reales.** Las pruebas usan cuentas y llaves
   ficticias (`AKIAIOSFODNN7EXAMPLE` es el ejemplo de la documentación de AWS).
4. **Sin dependencias nuevas para complacer al modelo.** Se mantuvo el proyecto
   sin paquetes externos aunque usar el SDK de AWS habría sido "más fácil".
5. **El humano revisa cada línea.** Código generado sin comprensión no entra.

## Errores de la IA que quedaron corregidos

Se documentan porque son representativos de lo que hay que vigilar:

| Error | Cómo se detectó | Corrección |
|---|---|---|
| El decodificador de *event stream* no saltaba el separador `\r\n\r\n`, así que desalineaba los mensajes. | Prueba unitaria con un frame sintético. | Se consume el separador y se valida el preludio. |
| `AWS4-HMAC-SHA256-PAYLOAD` no se usó al principio para el modo `tail`. | Revisión de la firma contra la documentación de AWS. | Se cambió a `InvokeFunction` con `RequestResponse` firmado normalmente. |
| El LED podía estar verde con la supervisión caída. | Revisión manual del estado. | Se añadió `effectiveStatus`, que refleja errores de conexión. |
| `Data.dropFirst` conserva los índices del slice; `.count` no era el esperado. | Comportamiento extraño en el bucle de decodificación. | Se reindexa siempre con `Data(...)`. |

## Cómo declarar IA en un PR

En la plantilla hay una sección dedicada. Indica:

- Qué herramienta usaste y para qué partes.
- Si quedó código generado que **no** has revisado línea a línea (en ese caso,
  no lo envíes).
- Cualquier comportamiento que no hayas podido verificar.

## Por qué documentarlo

- Quien revise necesita saber qué mirar con más cuidado.
- Puede haber patrones repetidos de error en código generado; si se detectan, se
  añaden pruebas que los atrapen.
- La transparencia es la única forma honesta de usar estas herramientas en un
  proyecto del que dependen procesos reales.
