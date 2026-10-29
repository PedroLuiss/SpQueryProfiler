# SP Query Profiler

Detecta bombas de tiempo en tus Stored Procedures de SQL Server antes de que exploten en producción.

SP Query Profiler es una aplicación de consola para desarrolladores y profesionales de bases de datos. Ejecuta una consulta o un Stored Procedure en SQL Server, obtiene su plan de ejecución XML e identifica operadores que pueden indicar trabajo costoso. También consulta las filas reales de las tablas identificadas y presenta los resultados en una tabla legible en la consola.

> **Importante:** para capturar el plan, la herramienta ejecuta la consulta que se le proporciona. Pruébala con consultas seguras y en una base de datos adecuada; un `EXEC` puede modificar datos igual que si se ejecutara directamente en SQL Server.

## Qué hace

1. Se conecta a SQL Server con la cadena de conexión proporcionada.
2. Activa `SET STATISTICS XML` y ejecuta la consulta.
3. Lee y analiza el plan XML buscando `Table Scan`, `Clustered Index Scan`, `Key Lookup` y `Sort`.
4. Para los operadores encontrados, muestra la tabla asociada, las filas estimadas y el costo estimado del subárbol.
5. Consulta `sys.dm_db_partition_stats` para obtener el número de filas de cada tabla identificada.
6. Imprime un reporte con colores y recomendaciones para los `Table Scan`.

Si no encuentra esos operadores, muestra un mensaje indicando que no se detectaron operadores de alto riesgo. La opción `--show-plan` permite imprimir el XML crudo para inspección.

## Requisitos

- .NET 10 SDK.
- SQL Server accesible desde el equipo donde se ejecuta la herramienta (local, remoto o en Docker).
- Permisos para conectarse y ejecutar la consulta indicada.
- Permisos de SQL Server para consultar `sys.dm_db_partition_stats`. En función de la versión y configuración del servidor, puede ser necesario que el usuario tenga permisos de estado/rendimiento de base de datos.

## Instalación

Clona o descarga este repositorio y abre una terminal en la carpeta que contiene `SpQueryProfiler.csproj`. Restaura los paquetes NuGet y compila:

```powershell
dotnet restore
dotnet build
```

No es necesario instalar la aplicación como herramienta global: se puede ejecutar directamente con `dotnet run`.

## Uso

Las opciones `--connection` y `--query` son obligatorias. También tienen las abreviaturas `-c` y `-q`.

```powershell
dotnet run -- -c "Server=localhost;Database=MiBase;Trusted_Connection=True;TrustServerCertificate=True" -q "EXEC dbo.TuSP"
```

Para analizar una consulta SQL directamente:

```powershell
dotnet run -- -c "Server=localhost;Database=MiBase;Trusted_Connection=True;TrustServerCertificate=True" -q "SELECT * FROM dbo.Orders WHERE CustomerId = 42"
```

Con autenticación de SQL Server:

```powershell
dotnet run -- -c "Server=localhost;Database=MiBase;User Id=mi_usuario;Password=TU_SQL_PASSWORD;TrustServerCertificate=True" -q "EXEC dbo.TuSP"
```

Para incluir el plan XML crudo en la salida:

```powershell
dotnet run -- -c "Server=localhost;Database=MiBase;Trusted_Connection=True;TrustServerCertificate=True" -q "EXEC dbo.TuSP" --show-plan
```

También se pueden usar los nombres largos:

```powershell
dotnet run -- --connection "Server=localhost;Database=MiBase;Trusted_Connection=True;TrustServerCertificate=True" --query "EXEC dbo.TuSP"
```

Para consultar las opciones disponibles:

```powershell
dotnet run -- --help
```

## Ejecutar desde Visual Studio

La aplicación es una CLI de una sola ejecución: realiza el análisis, imprime el reporte y termina. Si inicias la depuración con **F5**, Visual Studio puede cerrar la ventana de consola al finalizar el proceso. Esto es normal; la herramienta no está diseñada para quedarse esperando entrada.

Para pasarle argumentos desde Visual Studio:

1. En el Explorador de soluciones, haz clic derecho en el proyecto **SpQueryProfiler** y selecciona **Propiedades**.
2. Abre la sección **Depurar** y selecciona el perfil del proyecto.
3. En **Argumentos de la línea de comandos**, configura, por ejemplo:

   ```text
   -c "Server=.\SQLEXPRESS;Database=SpQueryProfilerDemo;Trusted_Connection=True;TrustServerCertificate=True" -q "EXEC dbo.GetOrdersByCustomer @CustomerId = 42, @Status = 'Pending'"
   ```

4. Guarda los cambios e inicia con **Ctrl+F5** (*Iniciar sin depurar*) para que Visual Studio mantenga la consola abierta al terminar. También puedes usar **F5** y consultar la salida en la ventana **Salida** de Visual Studio.

Otra opción es abrir una terminal en la carpeta del proyecto y ejecutar `dotnet run` con los argumentos del apartado anterior; de esa forma la salida permanece visible en la terminal.

## Datos de demostración

El archivo [`seed.sql`](./seed.sql) crea la base `SpQueryProfilerDemo`, carga 100,000 pedidos de ejemplo y crea el procedimiento `dbo.GetOrdersByCustomer`. Ejecútalo en una instancia de SQL Server usando SQL Server Management Studio o `sqlcmd`.

> El script está destinado a una base de datos de demostración: cada ejecución elimina y vuelve a crear `dbo.Orders`.

Después, ejecuta el procedimiento con la cadena de conexión de tu instancia:

```powershell
sqlcmd -S ".\SQLEXPRESS" -E -i .\seed.sql
dotnet run -- -c "Server=.\SQLEXPRESS;Database=SpQueryProfilerDemo;Trusted_Connection=True;TrustServerCertificate=True" -q "EXEC dbo.GetOrdersByCustomer @CustomerId = 42, @Status = 'Pending'"
```

### Procedimiento avanzado comentado

El archivo [`advanced_orders_procedure.sql`](./advanced_orders_procedure.sql) instala `dbo.usp_ProfileOrdersAdvanced`, una versión más extensa para estudiar filtros opcionales, validaciones, paginación, ordenamiento permitido y métricas por estado, mes, segmento de cliente, importe, día de semana y periodos recientes. Cada línea SQL tiene un comentario explicativo. El script incluye al final una llamada de ejemplo.

Instálalo después de `seed.sql`:

```powershell
sqlcmd -S ".\SQLEXPRESS" -E -i .\advanced_orders_procedure.sql
```

Después puedes analizarlo con el profiler:

```powershell
dotnet run -- -c "Server=.\SQLEXPRESS;Database=SpQueryProfilerDemo;Trusted_Connection=True;TrustServerCertificate=True" -q "EXEC dbo.usp_ProfileOrdersAdvanced @CustomerId = 42, @Status = 'Pending', @PageSize = 10, @IncludeSummary = 1"
```

## Ejemplo de reporte

La salida muestra una tabla con las columnas **Operador**, **Tabla**, **Filas reales** y **Costo estimado**. Los operadores de mayor riesgo y costos altos se resaltan en rojo; el resumen puede sugerir revisar índices para las tablas con `Table Scan`.

![Demo del CLI](demo.gif)

## ¿Por qué lo construí?

SP Query Profiler nace de la necesidad real de migrar sistemas y optimizar consultas en SQL Server. La herramienta busca ayudar a detectar operaciones potencialmente costosas en los planes de ejecución antes de que afecten el rendimiento en producción.
