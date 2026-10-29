-- SP Query Profiler: procedimiento avanzado de analisis para SpQueryProfilerDemo.dbo.Orders.
-- Ejecuta seed.sql primero; todas las lineas SQL tienen comentario explicativo.
USE [SpQueryProfilerDemo];                                                                           -- Selecciona la base de datos de demostracion.
GO                                                                                                   -- Envia el cambio de base como lote separado.
CREATE OR ALTER PROCEDURE dbo.usp_ProfileOrdersAdvanced                                              -- Crea o actualiza el procedimiento avanzado.
    @CustomerId int = NULL,                                                                          -- Filtra por cliente cuando se proporciona un identificador.
    @Status varchar(20) = NULL,                                                                      -- Filtra por estado exacto cuando se proporciona un valor.
    @StartDate date = NULL,                                                                          -- Establece la primera fecha incluida en el analisis.
    @EndDate date = NULL,                                                                            -- Establece la ultima fecha incluida en el analisis.
    @MinTotal decimal(12, 2) = NULL,                                                                 -- Establece el importe minimo que debe tener un pedido.
    @MaxTotal decimal(12, 2) = NULL,                                                                 -- Establece el importe maximo que debe tener un pedido.
    @SearchText nvarchar(50) = NULL,                                                                 -- Busca un fragmento de texto en el estado del pedido.
    @PageNumber int = 1,                                                                             -- Selecciona la pagina de pedidos que se devolvera.
    @PageSize int = 25,                                                                              -- Selecciona cuantos pedidos contiene cada pagina.
    @SortColumn sysname = N'OrderDate',                                                              -- Selecciona una columna permitida para ordenar los resultados.
    @SortDirection varchar(4) = 'DESC',                                                              -- Selecciona orden ascendente o descendente.
    @IncludeSummary bit = 1                                                                          -- Activa la salida adicional de metricas analiticas.
AS                                                                                                   -- Inicia la definicion del cuerpo del procedimiento.
BEGIN                                                                                                -- Abre el bloque principal del procedimiento.
    SET NOCOUNT ON;                                                                                  -- Evita mensajes de filas afectadas entre los resultados.
    SET XACT_ABORT ON;                                                                               -- Hace que ciertos errores aborten la instruccion activa.
    DECLARE @StartedAt datetime2(3) = SYSUTCDATETIME();                                              -- Registra la hora UTC de inicio de esta ejecucion.
    DECLARE @Offset bigint;                                                                          -- Reserva el desplazamiento de filas de la pagina elegida.
    DECLARE @EffectivePageSize int;                                                                  -- Guarda el tamano de pagina limitado por seguridad.
    DECLARE @FilteredRowCount bigint = 0;                                                            -- Guarda el total de pedidos que cumplen los filtros.
    DECLARE @AverageOrderTotal decimal(12, 2);                                                       -- Reserva el promedio del importe para metricas posteriores.
    DECLARE @NormalizedSearchText nvarchar(50);                                                      -- Reserva el texto de busqueda normalizado.
    IF @PageNumber IS NULL OR @PageNumber < 1                                                        -- Rechaza numeros de pagina menores que uno.
    BEGIN                                                                                            -- Abre el bloque de validacion del numero de pagina.
        THROW 51001, 'PageNumber debe ser mayor que cero.', 1;                                       -- Devuelve un error si el numero de pagina no es valido.
    END;                                                                                             -- Cierra la validacion del numero de pagina.
    IF @PageSize IS NULL OR @PageSize < 1                                                            -- Rechaza tamanos de pagina menores que uno.
    BEGIN                                                                                            -- Abre el bloque de validacion del tamano de pagina.
        THROW 51002, 'PageSize debe ser mayor que cero.', 1;                                         -- Devuelve un error si el tamano de pagina no es valido.
    END;                                                                                             -- Cierra la validacion del tamano de pagina.
    SET @EffectivePageSize = CASE WHEN @PageSize > 500 THEN 500 ELSE @PageSize END;                  -- Limita la pagina a un maximo de quinientas filas.
    SET @Offset = (CONVERT(bigint, @PageNumber) - 1) * @EffectivePageSize;                           -- Calcula el desplazamiento con bigint para evitar desbordamiento int.
    IF @StartDate IS NOT NULL AND @EndDate IS NOT NULL AND @StartDate > @EndDate                     -- Detecta un rango de fechas invertido.
    BEGIN                                                                                            -- Abre el bloque de validacion del rango de fechas.
        THROW 51003, 'StartDate no puede ser posterior a EndDate.', 1;                               -- Explica el error de fechas al consumidor del procedimiento.
    END;                                                                                             -- Cierra la validacion del rango de fechas.
    IF @MinTotal IS NOT NULL AND @MaxTotal IS NOT NULL AND @MinTotal > @MaxTotal                     -- Detecta limites de importe invertidos.
    BEGIN                                                                                            -- Abre el bloque de validacion de importes.
        THROW 51004, 'MinTotal no puede superar MaxTotal.', 1;                                       -- Explica el error en los limites de importe.
    END;                                                                                             -- Cierra la validacion de importes.
    SET @SortDirection = UPPER(LTRIM(RTRIM(COALESCE(@SortDirection, ''))));                          -- Normaliza la direccion de ordenamiento.
    IF @SortDirection NOT IN ('ASC', 'DESC')                                                         -- Permite unicamente las direcciones ASC y DESC.
    BEGIN                                                                                            -- Abre el bloque de validacion de direccion.
        THROW 51005, 'SortDirection debe ser ASC o DESC.', 1;                                        -- Informa los valores permitidos para la direccion.
    END;                                                                                             -- Cierra la validacion de direccion.
    SET @SortColumn = LOWER(LTRIM(RTRIM(COALESCE(@SortColumn, N''))));                               -- Normaliza la columna solicitada para validarla.
    IF @SortColumn NOT IN (N'id', N'customerid', N'orderdate', N'status', N'total')                  -- Usa una lista permitida y evita SQL dinamico para ordenar.
    BEGIN                                                                                            -- Abre el bloque de validacion de columna.
        THROW 51006, 'SortColumn debe ser Id, CustomerId, OrderDate, Status o Total.', 1;            -- Enumera las columnas aceptadas.
    END;                                                                                             -- Cierra la validacion de columna.
    SET @NormalizedSearchText = NULLIF(LTRIM(RTRIM(@SearchText)), N'');                              -- Ignora una busqueda que solo contiene espacios.
    CREATE TABLE #FilteredOrders                                                                     -- Crea un conjunto temporal para filtrar una sola vez.
    (                                                                                                -- Abre la lista de columnas temporales.
        Id int NOT NULL,                                                                             -- Almacena el identificador de cada pedido.
        CustomerId int NOT NULL,                                                                     -- Almacena el identificador del cliente.
        OrderDate date NOT NULL,                                                                     -- Almacena la fecha del pedido.
        Status varchar(20) NOT NULL,                                                                 -- Almacena el estado del pedido.
        Total decimal(12, 2) NOT NULL                                                                -- Almacena el importe total del pedido.
    );                                                                                               -- Cierra la definicion de la tabla temporal.
    INSERT INTO #FilteredOrders (Id, CustomerId, OrderDate, Status, Total)                           -- Materializa los pedidos que coinciden con los parametros.
    SELECT o.Id, o.CustomerId, o.OrderDate, o.Status, o.Total                                        -- Selecciona unicamente los campos necesarios para el analisis.
    FROM dbo.Orders AS o                                                                             -- Lee la tabla de pedidos de demostracion.
    WHERE (@CustomerId IS NULL OR o.CustomerId = @CustomerId)                                        -- Aplica el filtro opcional de cliente.
      AND (@Status IS NULL OR o.Status = @Status)                                                    -- Aplica el filtro opcional de estado exacto.
      AND (@StartDate IS NULL OR o.OrderDate >= @StartDate)                                          -- Incluye pedidos a partir de la fecha inicial.
      AND (@EndDate IS NULL OR o.OrderDate <= @EndDate)                                              -- Incluye pedidos hasta la fecha final inclusive.
      AND (@MinTotal IS NULL OR o.Total >= @MinTotal)                                                -- Aplica el importe minimo opcional.
      AND (@MaxTotal IS NULL OR o.Total <= @MaxTotal)                                                -- Aplica el importe maximo opcional.
      AND (@NormalizedSearchText IS NULL OR o.Status LIKE N'%' + @NormalizedSearchText + N'%');      -- Aplica la busqueda parcial solo si se indico texto.
    CREATE CLUSTERED INDEX CX_FilteredOrders_Id ON #FilteredOrders (Id);                             -- Indexa la tabla temporal por Id para busquedas y orden estable.
    SELECT @FilteredRowCount = COUNT_BIG(*) FROM #FilteredOrders;                                    -- Cuenta todas las filas filtradas incluso si la pagina queda vacia.
    SELECT @AverageOrderTotal = AVG(Total) FROM #FilteredOrders;                                     -- Calcula el promedio una sola vez para comparaciones posteriores.
    ;WITH RankedOrders AS                                                                            -- Inicia una expresion comun para numerar los pedidos filtrados.
    (                                                                                                -- Abre la consulta que asigna posiciones de pagina.
        SELECT fo.Id, fo.CustomerId, fo.OrderDate, fo.Status, fo.Total,                              -- Proyecta los campos que apareceran en la primera salida.
               ROW_NUMBER() OVER (ORDER BY                                                           -- Calcula una posicion reproducible para cada pedido.
                   CASE WHEN @SortColumn = N'orderdate' AND @SortDirection = 'ASC' THEN fo.OrderDate END ASC, -- Ordena por fecha en sentido ascendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'orderdate' AND @SortDirection = 'DESC' THEN fo.OrderDate END DESC, -- Ordena por fecha en sentido descendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'id' AND @SortDirection = 'ASC' THEN fo.Id END ASC,      -- Ordena por Id ascendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'id' AND @SortDirection = 'DESC' THEN fo.Id END DESC,    -- Ordena por Id descendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'customerid' AND @SortDirection = 'ASC' THEN fo.CustomerId END ASC, -- Ordena por cliente ascendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'customerid' AND @SortDirection = 'DESC' THEN fo.CustomerId END DESC, -- Ordena por cliente descendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'total' AND @SortDirection = 'ASC' THEN fo.Total END ASC, -- Ordena por total ascendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'total' AND @SortDirection = 'DESC' THEN fo.Total END DESC, -- Ordena por total descendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'status' AND @SortDirection = 'ASC' THEN fo.Status END ASC, -- Ordena por estado ascendente cuando se selecciona.
                   CASE WHEN @SortColumn = N'status' AND @SortDirection = 'DESC' THEN fo.Status END DESC, -- Ordena por estado descendente cuando se selecciona.
                   fo.Id ASC) AS RowNumber                                                           -- Usa Id como desempate estable y asigna nombre a la posicion.
        FROM #FilteredOrders AS fo                                                                   -- Numera las filas ya filtradas sin volver a consultar la tabla original.
    )                                                                                                -- Cierra la expresion comun de pedidos numerados.
    SELECT ro.Id, ro.CustomerId, ro.OrderDate, ro.Status, ro.Total, ro.RowNumber,                    -- Prepara las filas de la pagina y su posicion.
           @FilteredRowCount AS TotalMatchingOrders, @EffectivePageSize AS EffectivePageSize, @PageNumber AS PageNumber -- Incluye el total y los parametros de paginacion aplicados.
    FROM RankedOrders AS ro                                                                          -- Lee los pedidos ordenados desde la expresion comun.
    WHERE ro.RowNumber > @Offset AND ro.RowNumber <= @Offset + @EffectivePageSize                    -- Selecciona solo las filas pertenecientes a la pagina solicitada.
    ORDER BY ro.RowNumber;                                                                           -- Devuelve la pagina en el orden calculado.
    IF @IncludeSummary = 1                                                                           -- Genera metricas unicamente si el usuario las solicita.
    BEGIN                                                                                            -- Abre el bloque opcional del resumen analitico.
        CREATE TABLE #Metrics                                                                        -- Crea una tabla temporal para organizar las metricas.
        (                                                                                            -- Abre la lista de columnas de metricas.
            MetricGroup nvarchar(64) NOT NULL,                                                       -- Clasifica la metrica por dimension del analisis.
            MetricName nvarchar(128) NOT NULL,                                                       -- Almacena un nombre comprensible para la metrica.
            MetricValue nvarchar(4000) NULL                                                          -- Almacena el valor convertido a texto para presentarlo facilmente.
        );                                                                                           -- Cierra la definicion de la tabla de metricas.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Registra la hora en que comenzo este analisis.
        SELECT N'Execution', N'Started UTC', CONVERT(nvarchar(4000), @StartedAt, 126);               -- Devuelve la fecha de inicio en formato ISO.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Registra el total de pedidos filtrados.
        SELECT N'Execution', N'Filtered order count', CONVERT(nvarchar(4000), @FilteredRowCount);    -- Incluye el tamano completo del resultado filtrado.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Registra el tamano de pagina efectivo.
        SELECT N'Execution', N'Effective page size', CONVERT(nvarchar(4000), @EffectivePageSize);    -- Incluye el maximo de filas permitido en una pagina.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Registra el desplazamiento usado para la pagina.
        SELECT N'Execution', N'Page offset', CONVERT(nvarchar(4000), @Offset);                       -- Permite entender desde que fila se genero la pagina.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Registra la hora de generacion del resumen.
        SELECT N'Execution', N'Summary generated UTC', CONVERT(nvarchar(4000), SYSUTCDATETIME(), 126); -- Marca el momento UTC en que se produjo el informe.
-- Metrica: Filtered order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Filtered order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Filtered order count.
            N'General' AS MetricGroup,                                                               -- Clasifica Filtered order count dentro del grupo General.
            N'Filtered order count' AS MetricName,                                                   -- Asigna una etiqueta legible a Filtered order count.
            CONVERT(nvarchar(4000), COUNT_BIG(*)) AS MetricValue                                     -- Calcula y convierte el valor de Filtered order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Filtered order count sobre las filas filtradas.
-- Metrica: Distinct customer count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Distinct customer count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Distinct customer count.
            N'General' AS MetricGroup,                                                               -- Clasifica Distinct customer count dentro del grupo General.
            N'Distinct customer count' AS MetricName,                                                -- Asigna una etiqueta legible a Distinct customer count.
            CONVERT(nvarchar(4000), COUNT_BIG(DISTINCT fo.CustomerId)) AS MetricValue                -- Calcula y convierte el valor de Distinct customer count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Distinct customer count sobre las filas filtradas.
-- Metrica: Total sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Total sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Total sales.
            N'General' AS MetricGroup,                                                               -- Clasifica Total sales dentro del grupo General.
            N'Total sales' AS MetricName,                                                            -- Asigna una etiqueta legible a Total sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(fo.Total), 0)) AS MetricValue                       -- Calcula y convierte el valor de Total sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Total sales sobre las filas filtradas.
-- Metrica: Average order total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Average order total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Average order total.
            N'General' AS MetricGroup,                                                               -- Clasifica Average order total dentro del grupo General.
            N'Average order total' AS MetricName,                                                    -- Asigna una etiqueta legible a Average order total.
            CONVERT(nvarchar(4000), AVG(fo.Total)) AS MetricValue                                    -- Calcula y convierte el valor de Average order total.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Average order total sobre las filas filtradas.
-- Metrica: Smallest order total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Smallest order total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Smallest order total.
            N'General' AS MetricGroup,                                                               -- Clasifica Smallest order total dentro del grupo General.
            N'Smallest order total' AS MetricName,                                                   -- Asigna una etiqueta legible a Smallest order total.
            CONVERT(nvarchar(4000), MIN(fo.Total)) AS MetricValue                                    -- Calcula y convierte el valor de Smallest order total.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Smallest order total sobre las filas filtradas.
-- Metrica: Largest order total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Largest order total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Largest order total.
            N'General' AS MetricGroup,                                                               -- Clasifica Largest order total dentro del grupo General.
            N'Largest order total' AS MetricName,                                                    -- Asigna una etiqueta legible a Largest order total.
            CONVERT(nvarchar(4000), MAX(fo.Total)) AS MetricValue                                    -- Calcula y convierte el valor de Largest order total.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Largest order total sobre las filas filtradas.
-- Metrica: First order date.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica First order date.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica First order date.
            N'General' AS MetricGroup,                                                               -- Clasifica First order date dentro del grupo General.
            N'First order date' AS MetricName,                                                       -- Asigna una etiqueta legible a First order date.
            CONVERT(nvarchar(4000), MIN(fo.OrderDate)) AS MetricValue                                -- Calcula y convierte el valor de First order date.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula First order date sobre las filas filtradas.
-- Metrica: Last order date.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last order date.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last order date.
            N'General' AS MetricGroup,                                                               -- Clasifica Last order date dentro del grupo General.
            N'Last order date' AS MetricName,                                                        -- Asigna una etiqueta legible a Last order date.
            CONVERT(nvarchar(4000), MAX(fo.OrderDate)) AS MetricValue                                -- Calcula y convierte el valor de Last order date.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last order date sobre las filas filtradas.
-- Metrica: Orders with nonpositive total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Orders with nonpositive total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Orders with nonpositive total.
            N'General' AS MetricGroup,                                                               -- Clasifica Orders with nonpositive total dentro del grupo General.
            N'Orders with nonpositive total' AS MetricName,                                          -- Asigna una etiqueta legible a Orders with nonpositive total.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total <= 0 THEN 1 END)) AS MetricValue    -- Calcula y convierte el valor de Orders with nonpositive total.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Orders with nonpositive total sobre las filas filtradas.
-- Metrica: Orders above average value.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Orders above average value.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Orders above average value.
            N'General' AS MetricGroup,                                                               -- Clasifica Orders above average value dentro del grupo General.
            N'Orders above average value' AS MetricName,                                             -- Asigna una etiqueta legible a Orders above average value.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total > @AverageOrderTotal THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Orders above average value.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Orders above average value sobre las filas filtradas.
-- Metrica: Orders in current calendar year.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Orders in current calendar year.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Orders in current calendar year.
            N'General' AS MetricGroup,                                                               -- Clasifica Orders in current calendar year dentro del grupo General.
            N'Orders in current calendar year' AS MetricName,                                        -- Asigna una etiqueta legible a Orders in current calendar year.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEFROMPARTS(YEAR(GETDATE()), 1, 1) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Orders in current calendar year.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Orders in current calendar year sobre las filas filtradas.
-- Metrica: Sales in current calendar year.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Sales in current calendar year.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Sales in current calendar year.
            N'General' AS MetricGroup,                                                               -- Clasifica Sales in current calendar year dentro del grupo General.
            N'Sales in current calendar year' AS MetricName,                                         -- Asigna una etiqueta legible a Sales in current calendar year.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEFROMPARTS(YEAR(GETDATE()), 1, 1) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Sales in current calendar year.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Sales in current calendar year sobre las filas filtradas.
-- Metrica: Orders in previous calendar year.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Orders in previous calendar year.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Orders in previous calendar year.
            N'General' AS MetricGroup,                                                               -- Clasifica Orders in previous calendar year dentro del grupo General.
            N'Orders in previous calendar year' AS MetricName,                                       -- Asigna una etiqueta legible a Orders in previous calendar year.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEFROMPARTS(YEAR(GETDATE()) - 1, 1, 1) AND fo.OrderDate < DATEFROMPARTS(YEAR(GETDATE()), 1, 1) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Orders in previous calendar year.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Orders in previous calendar year sobre las filas filtradas.
-- Metrica: Sales in previous calendar year.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Sales in previous calendar year.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Sales in previous calendar year.
            N'General' AS MetricGroup,                                                               -- Clasifica Sales in previous calendar year dentro del grupo General.
            N'Sales in previous calendar year' AS MetricName,                                        -- Asigna una etiqueta legible a Sales in previous calendar year.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEFROMPARTS(YEAR(GETDATE()) - 1, 1, 1) AND fo.OrderDate < DATEFROMPARTS(YEAR(GETDATE()), 1, 1) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Sales in previous calendar year.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Sales in previous calendar year sobre las filas filtradas.
-- Metrica: Pending order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Pending order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Pending order count.
            N'Status' AS MetricGroup,                                                                -- Clasifica Pending order count dentro del grupo Status.
            N'Pending order count' AS MetricName,                                                    -- Asigna una etiqueta legible a Pending order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Status = 'Pending' THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Pending order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Pending order count sobre las filas filtradas.
-- Metrica: Pending sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Pending sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Pending sales.
            N'Status' AS MetricGroup,                                                                -- Clasifica Pending sales dentro del grupo Status.
            N'Pending sales' AS MetricName,                                                          -- Asigna una etiqueta legible a Pending sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Status = 'Pending' THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Pending sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Pending sales sobre las filas filtradas.
-- Metrica: Pending average order total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Pending average order total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Pending average order total.
            N'Status' AS MetricGroup,                                                                -- Clasifica Pending average order total dentro del grupo Status.
            N'Pending average order total' AS MetricName,                                            -- Asigna una etiqueta legible a Pending average order total.
            CONVERT(nvarchar(4000), SUM(CASE WHEN fo.Status = 'Pending' THEN fo.Total ELSE 0 END) / NULLIF(COUNT_BIG(CASE WHEN fo.Status = 'Pending' THEN 1 END), 0)) AS MetricValue -- Calcula el promedio pendiente sin dividir por cero.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Pending average order total sobre las filas filtradas.
-- Metrica: Pending distinct customers.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Pending distinct customers.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Pending distinct customers.
            N'Status' AS MetricGroup,                                                                -- Clasifica Pending distinct customers dentro del grupo Status.
            N'Pending distinct customers' AS MetricName,                                             -- Asigna una etiqueta legible a Pending distinct customers.
            CONVERT(nvarchar(4000), COUNT_BIG(DISTINCT CASE WHEN fo.Status = 'Pending' THEN fo.CustomerId END)) AS MetricValue -- Calcula y convierte el valor de Pending distinct customers.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Pending distinct customers sobre las filas filtradas.
-- Metrica: Pending largest order.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Pending largest order.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Pending largest order.
            N'Status' AS MetricGroup,                                                                -- Clasifica Pending largest order dentro del grupo Status.
            N'Pending largest order' AS MetricName,                                                  -- Asigna una etiqueta legible a Pending largest order.
            CONVERT(nvarchar(4000), MAX(CASE WHEN fo.Status = 'Pending' THEN fo.Total END)) AS MetricValue -- Calcula y convierte el valor de Pending largest order.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Pending largest order sobre las filas filtradas.
-- Metrica: Shipped order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Shipped order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Shipped order count.
            N'Status' AS MetricGroup,                                                                -- Clasifica Shipped order count dentro del grupo Status.
            N'Shipped order count' AS MetricName,                                                    -- Asigna una etiqueta legible a Shipped order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Status = 'Shipped' THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Shipped order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Shipped order count sobre las filas filtradas.
-- Metrica: Shipped sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Shipped sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Shipped sales.
            N'Status' AS MetricGroup,                                                                -- Clasifica Shipped sales dentro del grupo Status.
            N'Shipped sales' AS MetricName,                                                          -- Asigna una etiqueta legible a Shipped sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Status = 'Shipped' THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Shipped sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Shipped sales sobre las filas filtradas.
-- Metrica: Shipped average order total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Shipped average order total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Shipped average order total.
            N'Status' AS MetricGroup,                                                                -- Clasifica Shipped average order total dentro del grupo Status.
            N'Shipped average order total' AS MetricName,                                            -- Asigna una etiqueta legible a Shipped average order total.
            CONVERT(nvarchar(4000), SUM(CASE WHEN fo.Status = 'Shipped' THEN fo.Total ELSE 0 END) / NULLIF(COUNT_BIG(CASE WHEN fo.Status = 'Shipped' THEN 1 END), 0)) AS MetricValue -- Calcula el promedio enviado sin dividir por cero.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Shipped average order total sobre las filas filtradas.
-- Metrica: Shipped distinct customers.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Shipped distinct customers.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Shipped distinct customers.
            N'Status' AS MetricGroup,                                                                -- Clasifica Shipped distinct customers dentro del grupo Status.
            N'Shipped distinct customers' AS MetricName,                                             -- Asigna una etiqueta legible a Shipped distinct customers.
            CONVERT(nvarchar(4000), COUNT_BIG(DISTINCT CASE WHEN fo.Status = 'Shipped' THEN fo.CustomerId END)) AS MetricValue -- Calcula y convierte el valor de Shipped distinct customers.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Shipped distinct customers sobre las filas filtradas.
-- Metrica: Shipped largest order.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Shipped largest order.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Shipped largest order.
            N'Status' AS MetricGroup,                                                                -- Clasifica Shipped largest order dentro del grupo Status.
            N'Shipped largest order' AS MetricName,                                                  -- Asigna una etiqueta legible a Shipped largest order.
            CONVERT(nvarchar(4000), MAX(CASE WHEN fo.Status = 'Shipped' THEN fo.Total END)) AS MetricValue -- Calcula y convierte el valor de Shipped largest order.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Shipped largest order sobre las filas filtradas.
-- Metrica: Cancelled order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Cancelled order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Cancelled order count.
            N'Status' AS MetricGroup,                                                                -- Clasifica Cancelled order count dentro del grupo Status.
            N'Cancelled order count' AS MetricName,                                                  -- Asigna una etiqueta legible a Cancelled order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Status = 'Cancelled' THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Cancelled order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Cancelled order count sobre las filas filtradas.
-- Metrica: Cancelled sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Cancelled sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Cancelled sales.
            N'Status' AS MetricGroup,                                                                -- Clasifica Cancelled sales dentro del grupo Status.
            N'Cancelled sales' AS MetricName,                                                        -- Asigna una etiqueta legible a Cancelled sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Status = 'Cancelled' THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Cancelled sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Cancelled sales sobre las filas filtradas.
-- Metrica: Cancelled average order total.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Cancelled average order total.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Cancelled average order total.
            N'Status' AS MetricGroup,                                                                -- Clasifica Cancelled average order total dentro del grupo Status.
            N'Cancelled average order total' AS MetricName,                                          -- Asigna una etiqueta legible a Cancelled average order total.
            CONVERT(nvarchar(4000), SUM(CASE WHEN fo.Status = 'Cancelled' THEN fo.Total ELSE 0 END) / NULLIF(COUNT_BIG(CASE WHEN fo.Status = 'Cancelled' THEN 1 END), 0)) AS MetricValue -- Calcula el promedio cancelado sin dividir por cero.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Cancelled average order total sobre las filas filtradas.
-- Metrica: Cancelled distinct customers.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Cancelled distinct customers.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Cancelled distinct customers.
            N'Status' AS MetricGroup,                                                                -- Clasifica Cancelled distinct customers dentro del grupo Status.
            N'Cancelled distinct customers' AS MetricName,                                           -- Asigna una etiqueta legible a Cancelled distinct customers.
            CONVERT(nvarchar(4000), COUNT_BIG(DISTINCT CASE WHEN fo.Status = 'Cancelled' THEN fo.CustomerId END)) AS MetricValue -- Calcula y convierte el valor de Cancelled distinct customers.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Cancelled distinct customers sobre las filas filtradas.
-- Metrica: Cancelled largest order.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Cancelled largest order.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Cancelled largest order.
            N'Status' AS MetricGroup,                                                                -- Clasifica Cancelled largest order dentro del grupo Status.
            N'Cancelled largest order' AS MetricName,                                                -- Asigna una etiqueta legible a Cancelled largest order.
            CONVERT(nvarchar(4000), MAX(CASE WHEN fo.Status = 'Cancelled' THEN fo.Total END)) AS MetricValue -- Calcula y convierte el valor de Cancelled largest order.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Cancelled largest order sobre las filas filtradas.
-- Metrica: January order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica January order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica January order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica January order count dentro del grupo Calendar month.
            N'January order count' AS MetricName,                                                    -- Asigna una etiqueta legible a January order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 1 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de January order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula January order count sobre las filas filtradas.
-- Metrica: January sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica January sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica January sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica January sales dentro del grupo Calendar month.
            N'January sales' AS MetricName,                                                          -- Asigna una etiqueta legible a January sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 1 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de January sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula January sales sobre las filas filtradas.
-- Metrica: February order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica February order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica February order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica February order count dentro del grupo Calendar month.
            N'February order count' AS MetricName,                                                   -- Asigna una etiqueta legible a February order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 2 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de February order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula February order count sobre las filas filtradas.
-- Metrica: February sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica February sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica February sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica February sales dentro del grupo Calendar month.
            N'February sales' AS MetricName,                                                         -- Asigna una etiqueta legible a February sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 2 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de February sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula February sales sobre las filas filtradas.
-- Metrica: March order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica March order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica March order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica March order count dentro del grupo Calendar month.
            N'March order count' AS MetricName,                                                      -- Asigna una etiqueta legible a March order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 3 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de March order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula March order count sobre las filas filtradas.
-- Metrica: March sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica March sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica March sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica March sales dentro del grupo Calendar month.
            N'March sales' AS MetricName,                                                            -- Asigna una etiqueta legible a March sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 3 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de March sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula March sales sobre las filas filtradas.
-- Metrica: April order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica April order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica April order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica April order count dentro del grupo Calendar month.
            N'April order count' AS MetricName,                                                      -- Asigna una etiqueta legible a April order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 4 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de April order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula April order count sobre las filas filtradas.
-- Metrica: April sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica April sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica April sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica April sales dentro del grupo Calendar month.
            N'April sales' AS MetricName,                                                            -- Asigna una etiqueta legible a April sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 4 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de April sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula April sales sobre las filas filtradas.
-- Metrica: May order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica May order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica May order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica May order count dentro del grupo Calendar month.
            N'May order count' AS MetricName,                                                        -- Asigna una etiqueta legible a May order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 5 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de May order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula May order count sobre las filas filtradas.
-- Metrica: May sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica May sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica May sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica May sales dentro del grupo Calendar month.
            N'May sales' AS MetricName,                                                              -- Asigna una etiqueta legible a May sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 5 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de May sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula May sales sobre las filas filtradas.
-- Metrica: June order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica June order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica June order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica June order count dentro del grupo Calendar month.
            N'June order count' AS MetricName,                                                       -- Asigna una etiqueta legible a June order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 6 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de June order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula June order count sobre las filas filtradas.
-- Metrica: June sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica June sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica June sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica June sales dentro del grupo Calendar month.
            N'June sales' AS MetricName,                                                             -- Asigna una etiqueta legible a June sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 6 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de June sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula June sales sobre las filas filtradas.
-- Metrica: July order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica July order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica July order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica July order count dentro del grupo Calendar month.
            N'July order count' AS MetricName,                                                       -- Asigna una etiqueta legible a July order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 7 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de July order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula July order count sobre las filas filtradas.
-- Metrica: July sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica July sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica July sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica July sales dentro del grupo Calendar month.
            N'July sales' AS MetricName,                                                             -- Asigna una etiqueta legible a July sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 7 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de July sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula July sales sobre las filas filtradas.
-- Metrica: August order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica August order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica August order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica August order count dentro del grupo Calendar month.
            N'August order count' AS MetricName,                                                     -- Asigna una etiqueta legible a August order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 8 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de August order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula August order count sobre las filas filtradas.
-- Metrica: August sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica August sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica August sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica August sales dentro del grupo Calendar month.
            N'August sales' AS MetricName,                                                           -- Asigna una etiqueta legible a August sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 8 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de August sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula August sales sobre las filas filtradas.
-- Metrica: September order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica September order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica September order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica September order count dentro del grupo Calendar month.
            N'September order count' AS MetricName,                                                  -- Asigna una etiqueta legible a September order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 9 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de September order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula September order count sobre las filas filtradas.
-- Metrica: September sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica September sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica September sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica September sales dentro del grupo Calendar month.
            N'September sales' AS MetricName,                                                        -- Asigna una etiqueta legible a September sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 9 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de September sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula September sales sobre las filas filtradas.
-- Metrica: October order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica October order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica October order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica October order count dentro del grupo Calendar month.
            N'October order count' AS MetricName,                                                    -- Asigna una etiqueta legible a October order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 10 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de October order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula October order count sobre las filas filtradas.
-- Metrica: October sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica October sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica October sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica October sales dentro del grupo Calendar month.
            N'October sales' AS MetricName,                                                          -- Asigna una etiqueta legible a October sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 10 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de October sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula October sales sobre las filas filtradas.
-- Metrica: November order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica November order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica November order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica November order count dentro del grupo Calendar month.
            N'November order count' AS MetricName,                                                   -- Asigna una etiqueta legible a November order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 11 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de November order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula November order count sobre las filas filtradas.
-- Metrica: November sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica November sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica November sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica November sales dentro del grupo Calendar month.
            N'November sales' AS MetricName,                                                         -- Asigna una etiqueta legible a November sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 11 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de November sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula November sales sobre las filas filtradas.
-- Metrica: December order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica December order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica December order count.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica December order count dentro del grupo Calendar month.
            N'December order count' AS MetricName,                                                   -- Asigna una etiqueta legible a December order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN MONTH(fo.OrderDate) = 12 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de December order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula December order count sobre las filas filtradas.
-- Metrica: December sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica December sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica December sales.
            N'Calendar month' AS MetricGroup,                                                        -- Clasifica December sales dentro del grupo Calendar month.
            N'December sales' AS MetricName,                                                         -- Asigna una etiqueta legible a December sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN MONTH(fo.OrderDate) = 12 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de December sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula December sales sobre las filas filtradas.
-- Metrica: Customers 1-100 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 1-100 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 1-100 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 1-100 order count dentro del grupo Customer segment.
            N'Customers 1-100 order count' AS MetricName,                                            -- Asigna una etiqueta legible a Customers 1-100 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 1 AND 100 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 1-100 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 1-100 order count sobre las filas filtradas.
-- Metrica: Customers 1-100 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 1-100 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 1-100 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 1-100 sales dentro del grupo Customer segment.
            N'Customers 1-100 sales' AS MetricName,                                                  -- Asigna una etiqueta legible a Customers 1-100 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 1 AND 100 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 1-100 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 1-100 sales sobre las filas filtradas.
-- Metrica: Customers 101-200 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 101-200 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 101-200 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 101-200 order count dentro del grupo Customer segment.
            N'Customers 101-200 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 101-200 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 101 AND 200 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 101-200 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 101-200 order count sobre las filas filtradas.
-- Metrica: Customers 101-200 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 101-200 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 101-200 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 101-200 sales dentro del grupo Customer segment.
            N'Customers 101-200 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 101-200 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 101 AND 200 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 101-200 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 101-200 sales sobre las filas filtradas.
-- Metrica: Customers 201-300 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 201-300 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 201-300 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 201-300 order count dentro del grupo Customer segment.
            N'Customers 201-300 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 201-300 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 201 AND 300 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 201-300 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 201-300 order count sobre las filas filtradas.
-- Metrica: Customers 201-300 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 201-300 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 201-300 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 201-300 sales dentro del grupo Customer segment.
            N'Customers 201-300 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 201-300 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 201 AND 300 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 201-300 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 201-300 sales sobre las filas filtradas.
-- Metrica: Customers 301-400 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 301-400 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 301-400 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 301-400 order count dentro del grupo Customer segment.
            N'Customers 301-400 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 301-400 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 301 AND 400 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 301-400 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 301-400 order count sobre las filas filtradas.
-- Metrica: Customers 301-400 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 301-400 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 301-400 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 301-400 sales dentro del grupo Customer segment.
            N'Customers 301-400 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 301-400 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 301 AND 400 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 301-400 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 301-400 sales sobre las filas filtradas.
-- Metrica: Customers 401-500 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 401-500 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 401-500 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 401-500 order count dentro del grupo Customer segment.
            N'Customers 401-500 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 401-500 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 401 AND 500 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 401-500 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 401-500 order count sobre las filas filtradas.
-- Metrica: Customers 401-500 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 401-500 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 401-500 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 401-500 sales dentro del grupo Customer segment.
            N'Customers 401-500 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 401-500 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 401 AND 500 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 401-500 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 401-500 sales sobre las filas filtradas.
-- Metrica: Customers 501-600 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 501-600 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 501-600 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 501-600 order count dentro del grupo Customer segment.
            N'Customers 501-600 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 501-600 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 501 AND 600 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 501-600 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 501-600 order count sobre las filas filtradas.
-- Metrica: Customers 501-600 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 501-600 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 501-600 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 501-600 sales dentro del grupo Customer segment.
            N'Customers 501-600 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 501-600 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 501 AND 600 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 501-600 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 501-600 sales sobre las filas filtradas.
-- Metrica: Customers 601-700 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 601-700 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 601-700 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 601-700 order count dentro del grupo Customer segment.
            N'Customers 601-700 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 601-700 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 601 AND 700 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 601-700 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 601-700 order count sobre las filas filtradas.
-- Metrica: Customers 601-700 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 601-700 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 601-700 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 601-700 sales dentro del grupo Customer segment.
            N'Customers 601-700 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 601-700 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 601 AND 700 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 601-700 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 601-700 sales sobre las filas filtradas.
-- Metrica: Customers 701-800 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 701-800 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 701-800 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 701-800 order count dentro del grupo Customer segment.
            N'Customers 701-800 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 701-800 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 701 AND 800 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 701-800 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 701-800 order count sobre las filas filtradas.
-- Metrica: Customers 701-800 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 701-800 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 701-800 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 701-800 sales dentro del grupo Customer segment.
            N'Customers 701-800 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 701-800 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 701 AND 800 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 701-800 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 701-800 sales sobre las filas filtradas.
-- Metrica: Customers 801-900 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 801-900 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 801-900 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 801-900 order count dentro del grupo Customer segment.
            N'Customers 801-900 order count' AS MetricName,                                          -- Asigna una etiqueta legible a Customers 801-900 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 801 AND 900 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 801-900 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 801-900 order count sobre las filas filtradas.
-- Metrica: Customers 801-900 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 801-900 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 801-900 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 801-900 sales dentro del grupo Customer segment.
            N'Customers 801-900 sales' AS MetricName,                                                -- Asigna una etiqueta legible a Customers 801-900 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 801 AND 900 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 801-900 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 801-900 sales sobre las filas filtradas.
-- Metrica: Customers 901-1000 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 901-1000 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 901-1000 order count.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 901-1000 order count dentro del grupo Customer segment.
            N'Customers 901-1000 order count' AS MetricName,                                         -- Asigna una etiqueta legible a Customers 901-1000 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.CustomerId BETWEEN 901 AND 1000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Customers 901-1000 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 901-1000 order count sobre las filas filtradas.
-- Metrica: Customers 901-1000 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Customers 901-1000 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Customers 901-1000 sales.
            N'Customer segment' AS MetricGroup,                                                      -- Clasifica Customers 901-1000 sales dentro del grupo Customer segment.
            N'Customers 901-1000 sales' AS MetricName,                                               -- Asigna una etiqueta legible a Customers 901-1000 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.CustomerId BETWEEN 901 AND 1000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Customers 901-1000 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Customers 901-1000 sales sobre las filas filtradas.
-- Metrica: 0 to 99.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 0 to 99.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 0 to 99.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 0 to 99.99 order count dentro del grupo Order value band.
            N'0 to 99.99 order count' AS MetricName,                                                 -- Asigna una etiqueta legible a 0 to 99.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 0 AND fo.Total < 100 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 0 to 99.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 0 to 99.99 order count sobre las filas filtradas.
-- Metrica: 0 to 99.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 0 to 99.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 0 to 99.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 0 to 99.99 sales dentro del grupo Order value band.
            N'0 to 99.99 sales' AS MetricName,                                                       -- Asigna una etiqueta legible a 0 to 99.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 0 AND fo.Total < 100 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 0 to 99.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 0 to 99.99 sales sobre las filas filtradas.
-- Metrica: 100 to 499.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 100 to 499.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 100 to 499.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 100 to 499.99 order count dentro del grupo Order value band.
            N'100 to 499.99 order count' AS MetricName,                                              -- Asigna una etiqueta legible a 100 to 499.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 100 AND fo.Total < 500 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 100 to 499.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 100 to 499.99 order count sobre las filas filtradas.
-- Metrica: 100 to 499.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 100 to 499.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 100 to 499.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 100 to 499.99 sales dentro del grupo Order value band.
            N'100 to 499.99 sales' AS MetricName,                                                    -- Asigna una etiqueta legible a 100 to 499.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 100 AND fo.Total < 500 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 100 to 499.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 100 to 499.99 sales sobre las filas filtradas.
-- Metrica: 500 to 999.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 500 to 999.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 500 to 999.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 500 to 999.99 order count dentro del grupo Order value band.
            N'500 to 999.99 order count' AS MetricName,                                              -- Asigna una etiqueta legible a 500 to 999.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 500 AND fo.Total < 1000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 500 to 999.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 500 to 999.99 order count sobre las filas filtradas.
-- Metrica: 500 to 999.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 500 to 999.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 500 to 999.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 500 to 999.99 sales dentro del grupo Order value band.
            N'500 to 999.99 sales' AS MetricName,                                                    -- Asigna una etiqueta legible a 500 to 999.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 500 AND fo.Total < 1000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 500 to 999.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 500 to 999.99 sales sobre las filas filtradas.
-- Metrica: 1000 to 2499.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 1000 to 2499.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 1000 to 2499.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 1000 to 2499.99 order count dentro del grupo Order value band.
            N'1000 to 2499.99 order count' AS MetricName,                                            -- Asigna una etiqueta legible a 1000 to 2499.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 1000 AND fo.Total < 2500 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 1000 to 2499.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 1000 to 2499.99 order count sobre las filas filtradas.
-- Metrica: 1000 to 2499.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 1000 to 2499.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 1000 to 2499.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 1000 to 2499.99 sales dentro del grupo Order value band.
            N'1000 to 2499.99 sales' AS MetricName,                                                  -- Asigna una etiqueta legible a 1000 to 2499.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 1000 AND fo.Total < 2500 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 1000 to 2499.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 1000 to 2499.99 sales sobre las filas filtradas.
-- Metrica: 2500 to 4999.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 2500 to 4999.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 2500 to 4999.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 2500 to 4999.99 order count dentro del grupo Order value band.
            N'2500 to 4999.99 order count' AS MetricName,                                            -- Asigna una etiqueta legible a 2500 to 4999.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 2500 AND fo.Total < 5000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 2500 to 4999.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 2500 to 4999.99 order count sobre las filas filtradas.
-- Metrica: 2500 to 4999.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 2500 to 4999.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 2500 to 4999.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 2500 to 4999.99 sales dentro del grupo Order value band.
            N'2500 to 4999.99 sales' AS MetricName,                                                  -- Asigna una etiqueta legible a 2500 to 4999.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 2500 AND fo.Total < 5000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 2500 to 4999.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 2500 to 4999.99 sales sobre las filas filtradas.
-- Metrica: 5000 to 9999.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 5000 to 9999.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 5000 to 9999.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 5000 to 9999.99 order count dentro del grupo Order value band.
            N'5000 to 9999.99 order count' AS MetricName,                                            -- Asigna una etiqueta legible a 5000 to 9999.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 5000 AND fo.Total < 10000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 5000 to 9999.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 5000 to 9999.99 order count sobre las filas filtradas.
-- Metrica: 5000 to 9999.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 5000 to 9999.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 5000 to 9999.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 5000 to 9999.99 sales dentro del grupo Order value band.
            N'5000 to 9999.99 sales' AS MetricName,                                                  -- Asigna una etiqueta legible a 5000 to 9999.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 5000 AND fo.Total < 10000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 5000 to 9999.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 5000 to 9999.99 sales sobre las filas filtradas.
-- Metrica: 10000 to 19999.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 10000 to 19999.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 10000 to 19999.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 10000 to 19999.99 order count dentro del grupo Order value band.
            N'10000 to 19999.99 order count' AS MetricName,                                          -- Asigna una etiqueta legible a 10000 to 19999.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 10000 AND fo.Total < 20000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 10000 to 19999.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 10000 to 19999.99 order count sobre las filas filtradas.
-- Metrica: 10000 to 19999.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 10000 to 19999.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 10000 to 19999.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 10000 to 19999.99 sales dentro del grupo Order value band.
            N'10000 to 19999.99 sales' AS MetricName,                                                -- Asigna una etiqueta legible a 10000 to 19999.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 10000 AND fo.Total < 20000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 10000 to 19999.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 10000 to 19999.99 sales sobre las filas filtradas.
-- Metrica: 20000 to 49999.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 20000 to 49999.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 20000 to 49999.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 20000 to 49999.99 order count dentro del grupo Order value band.
            N'20000 to 49999.99 order count' AS MetricName,                                          -- Asigna una etiqueta legible a 20000 to 49999.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 20000 AND fo.Total < 50000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 20000 to 49999.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 20000 to 49999.99 order count sobre las filas filtradas.
-- Metrica: 20000 to 49999.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 20000 to 49999.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 20000 to 49999.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 20000 to 49999.99 sales dentro del grupo Order value band.
            N'20000 to 49999.99 sales' AS MetricName,                                                -- Asigna una etiqueta legible a 20000 to 49999.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 20000 AND fo.Total < 50000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 20000 to 49999.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 20000 to 49999.99 sales sobre las filas filtradas.
-- Metrica: 50000 to 99999.99 order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 50000 to 99999.99 order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 50000 to 99999.99 order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 50000 to 99999.99 order count dentro del grupo Order value band.
            N'50000 to 99999.99 order count' AS MetricName,                                          -- Asigna una etiqueta legible a 50000 to 99999.99 order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 50000 AND fo.Total < 100000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 50000 to 99999.99 order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 50000 to 99999.99 order count sobre las filas filtradas.
-- Metrica: 50000 to 99999.99 sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 50000 to 99999.99 sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 50000 to 99999.99 sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 50000 to 99999.99 sales dentro del grupo Order value band.
            N'50000 to 99999.99 sales' AS MetricName,                                                -- Asigna una etiqueta legible a 50000 to 99999.99 sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 50000 AND fo.Total < 100000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 50000 to 99999.99 sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 50000 to 99999.99 sales sobre las filas filtradas.
-- Metrica: 100000 or more order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 100000 or more order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 100000 or more order count.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 100000 or more order count dentro del grupo Order value band.
            N'100000 or more order count' AS MetricName,                                             -- Asigna una etiqueta legible a 100000 or more order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.Total >= 100000 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de 100000 or more order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 100000 or more order count sobre las filas filtradas.
-- Metrica: 100000 or more sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica 100000 or more sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica 100000 or more sales.
            N'Order value band' AS MetricGroup,                                                      -- Clasifica 100000 or more sales dentro del grupo Order value band.
            N'100000 or more sales' AS MetricName,                                                   -- Asigna una etiqueta legible a 100000 or more sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.Total >= 100000 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de 100000 or more sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula 100000 or more sales sobre las filas filtradas.
-- Metrica: Monday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Monday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Monday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Monday order count dentro del grupo Weekday.
            N'Monday order count' AS MetricName,                                                     -- Asigna una etiqueta legible a Monday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 0 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Monday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Monday order count sobre las filas filtradas.
-- Metrica: Monday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Monday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Monday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Monday sales dentro del grupo Weekday.
            N'Monday sales' AS MetricName,                                                           -- Asigna una etiqueta legible a Monday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 0 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Monday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Monday sales sobre las filas filtradas.
-- Metrica: Tuesday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Tuesday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Tuesday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Tuesday order count dentro del grupo Weekday.
            N'Tuesday order count' AS MetricName,                                                    -- Asigna una etiqueta legible a Tuesday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 1 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Tuesday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Tuesday order count sobre las filas filtradas.
-- Metrica: Tuesday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Tuesday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Tuesday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Tuesday sales dentro del grupo Weekday.
            N'Tuesday sales' AS MetricName,                                                          -- Asigna una etiqueta legible a Tuesday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 1 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Tuesday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Tuesday sales sobre las filas filtradas.
-- Metrica: Wednesday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Wednesday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Wednesday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Wednesday order count dentro del grupo Weekday.
            N'Wednesday order count' AS MetricName,                                                  -- Asigna una etiqueta legible a Wednesday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 2 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Wednesday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Wednesday order count sobre las filas filtradas.
-- Metrica: Wednesday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Wednesday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Wednesday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Wednesday sales dentro del grupo Weekday.
            N'Wednesday sales' AS MetricName,                                                        -- Asigna una etiqueta legible a Wednesday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 2 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Wednesday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Wednesday sales sobre las filas filtradas.
-- Metrica: Thursday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Thursday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Thursday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Thursday order count dentro del grupo Weekday.
            N'Thursday order count' AS MetricName,                                                   -- Asigna una etiqueta legible a Thursday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 3 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Thursday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Thursday order count sobre las filas filtradas.
-- Metrica: Thursday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Thursday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Thursday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Thursday sales dentro del grupo Weekday.
            N'Thursday sales' AS MetricName,                                                         -- Asigna una etiqueta legible a Thursday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 3 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Thursday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Thursday sales sobre las filas filtradas.
-- Metrica: Friday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Friday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Friday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Friday order count dentro del grupo Weekday.
            N'Friday order count' AS MetricName,                                                     -- Asigna una etiqueta legible a Friday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 4 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Friday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Friday order count sobre las filas filtradas.
-- Metrica: Friday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Friday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Friday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Friday sales dentro del grupo Weekday.
            N'Friday sales' AS MetricName,                                                           -- Asigna una etiqueta legible a Friday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 4 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Friday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Friday sales sobre las filas filtradas.
-- Metrica: Saturday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Saturday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Saturday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Saturday order count dentro del grupo Weekday.
            N'Saturday order count' AS MetricName,                                                   -- Asigna una etiqueta legible a Saturday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 5 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Saturday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Saturday order count sobre las filas filtradas.
-- Metrica: Saturday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Saturday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Saturday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Saturday sales dentro del grupo Weekday.
            N'Saturday sales' AS MetricName,                                                         -- Asigna una etiqueta legible a Saturday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 5 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Saturday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Saturday sales sobre las filas filtradas.
-- Metrica: Sunday order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Sunday order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Sunday order count.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Sunday order count dentro del grupo Weekday.
            N'Sunday order count' AS MetricName,                                                     -- Asigna una etiqueta legible a Sunday order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 6 THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Sunday order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Sunday order count sobre las filas filtradas.
-- Metrica: Sunday sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Sunday sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Sunday sales.
            N'Weekday' AS MetricGroup,                                                               -- Clasifica Sunday sales dentro del grupo Weekday.
            N'Sunday sales' AS MetricName,                                                           -- Asigna una etiqueta legible a Sunday sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN ((DATEDIFF(day, CONVERT(date, '19000101'), fo.OrderDate) % 7 + 7) % 7) = 6 THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Sunday sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Sunday sales sobre las filas filtradas.
-- Metrica: Last 7 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 7 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 7 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 7 days order count dentro del grupo Rolling period.
            N'Last 7 days order count' AS MetricName,                                                -- Asigna una etiqueta legible a Last 7 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -7, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 7 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 7 days order count sobre las filas filtradas.
-- Metrica: Last 7 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 7 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 7 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 7 days sales dentro del grupo Rolling period.
            N'Last 7 days sales' AS MetricName,                                                      -- Asigna una etiqueta legible a Last 7 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -7, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 7 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 7 days sales sobre las filas filtradas.
-- Metrica: Last 30 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 30 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 30 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 30 days order count dentro del grupo Rolling period.
            N'Last 30 days order count' AS MetricName,                                               -- Asigna una etiqueta legible a Last 30 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -30, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 30 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 30 days order count sobre las filas filtradas.
-- Metrica: Last 30 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 30 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 30 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 30 days sales dentro del grupo Rolling period.
            N'Last 30 days sales' AS MetricName,                                                     -- Asigna una etiqueta legible a Last 30 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -30, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 30 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 30 days sales sobre las filas filtradas.
-- Metrica: Last 90 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 90 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 90 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 90 days order count dentro del grupo Rolling period.
            N'Last 90 days order count' AS MetricName,                                               -- Asigna una etiqueta legible a Last 90 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -90, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 90 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 90 days order count sobre las filas filtradas.
-- Metrica: Last 90 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 90 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 90 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 90 days sales dentro del grupo Rolling period.
            N'Last 90 days sales' AS MetricName,                                                     -- Asigna una etiqueta legible a Last 90 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -90, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 90 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 90 days sales sobre las filas filtradas.
-- Metrica: Last 180 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 180 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 180 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 180 days order count dentro del grupo Rolling period.
            N'Last 180 days order count' AS MetricName,                                              -- Asigna una etiqueta legible a Last 180 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -180, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 180 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 180 days order count sobre las filas filtradas.
-- Metrica: Last 180 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 180 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 180 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 180 days sales dentro del grupo Rolling period.
            N'Last 180 days sales' AS MetricName,                                                    -- Asigna una etiqueta legible a Last 180 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -180, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 180 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 180 days sales sobre las filas filtradas.
-- Metrica: Last 365 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 365 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 365 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 365 days order count dentro del grupo Rolling period.
            N'Last 365 days order count' AS MetricName,                                              -- Asigna una etiqueta legible a Last 365 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -365, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 365 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 365 days order count sobre las filas filtradas.
-- Metrica: Last 365 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 365 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 365 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 365 days sales dentro del grupo Rolling period.
            N'Last 365 days sales' AS MetricName,                                                    -- Asigna una etiqueta legible a Last 365 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -365, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 365 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 365 days sales sobre las filas filtradas.
-- Metrica: Last 730 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 730 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 730 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 730 days order count dentro del grupo Rolling period.
            N'Last 730 days order count' AS MetricName,                                              -- Asigna una etiqueta legible a Last 730 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -730, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 730 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 730 days order count sobre las filas filtradas.
-- Metrica: Last 730 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 730 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 730 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 730 days sales dentro del grupo Rolling period.
            N'Last 730 days sales' AS MetricName,                                                    -- Asigna una etiqueta legible a Last 730 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -730, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 730 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 730 days sales sobre las filas filtradas.
-- Metrica: Last 1095 days order count.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 1095 days order count.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 1095 days order count.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 1095 days order count dentro del grupo Rolling period.
            N'Last 1095 days order count' AS MetricName,                                             -- Asigna una etiqueta legible a Last 1095 days order count.
            CONVERT(nvarchar(4000), COUNT_BIG(CASE WHEN fo.OrderDate >= DATEADD(day, -1095, CONVERT(date, GETDATE())) THEN 1 END)) AS MetricValue -- Calcula y convierte el valor de Last 1095 days order count.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 1095 days order count sobre las filas filtradas.
-- Metrica: Last 1095 days sales.
        INSERT INTO #Metrics (MetricGroup, MetricName, MetricValue)                                  -- Inicia el registro de la metrica Last 1095 days sales.
        SELECT                                                                                       -- Comienza la proyeccion de la metrica Last 1095 days sales.
            N'Rolling period' AS MetricGroup,                                                        -- Clasifica Last 1095 days sales dentro del grupo Rolling period.
            N'Last 1095 days sales' AS MetricName,                                                   -- Asigna una etiqueta legible a Last 1095 days sales.
            CONVERT(nvarchar(4000), COALESCE(SUM(CASE WHEN fo.OrderDate >= DATEADD(day, -1095, CONVERT(date, GETDATE())) THEN fo.Total ELSE 0 END), 0)) AS MetricValue -- Calcula y convierte el valor de Last 1095 days sales.
        FROM #FilteredOrders AS fo;                                                                  -- Calcula Last 1095 days sales sobre las filas filtradas.
        SELECT MetricGroup, MetricName, MetricValue                                                  -- Prepara la salida tabular de las metricas.
        FROM #Metrics                                                                                -- Lee todas las metricas acumuladas en la tabla temporal.
        ORDER BY MetricGroup, MetricName;                                                            -- Ordena el resumen por categoria y por nombre de metrica.
    END;                                                                                             -- Cierra la generacion opcional del resumen.
    DROP TABLE #FilteredOrders;                                                                      -- Libera explicitamente la tabla temporal de pedidos.
END;                                                                                                 -- Cierra el cuerpo del procedimiento avanzado.
GO                                                                                                   -- Compila la definicion como un lote separado.
-- Prueba opcional: el profiler mostrara el plan de este procedimiento y sus operadores.
EXEC dbo.usp_ProfileOrdersAdvanced                                                                   -- Ejecuta el procedimiento avanzado para probarlo desde SSMS.
    @CustomerId = 42,                                                                                -- Filtra el ejemplo por el cliente 42.
    @Status = 'Pending',                                                                             -- Filtra el ejemplo por pedidos pendientes.
    @StartDate = NULL,                                                                               -- No limita el ejemplo por fecha inicial.
    @EndDate = NULL,                                                                                 -- No limita el ejemplo por fecha final.
    @MinTotal = NULL,                                                                                -- No limita el ejemplo por importe minimo.
    @MaxTotal = NULL,                                                                                -- No limita el ejemplo por importe maximo.
    @SearchText = NULL,                                                                              -- No limita el ejemplo por texto parcial.
    @PageNumber = 1,                                                                                 -- Solicita la primera pagina.
    @PageSize = 25,                                                                                  -- Solicita veinticinco pedidos como maximo.
    @SortColumn = N'OrderDate',                                                                      -- Ordena por fecha del pedido.
    @SortDirection = 'DESC',                                                                         -- Muestra primero las fechas mas recientes.
    @IncludeSummary = 1;                                                                             -- Incluye todas las metricas calculadas como segundo resultado.
GO                                                                                                   -- Ejecuta la prueba opcional en un lote separado.
