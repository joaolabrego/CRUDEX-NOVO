USE [crudex];
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO
/*
    Config - esquema da planilha CRUDEX(1).xlsm (40 tabelas / 249 colunas).

    Modos preservados:
      DatabaseName NULL : valida o sistema; nenhum result set; RETURN 0.
      DatabaseName 'all': todos os metadados aplicáveis ao sistema.
      Outro nome       : dados de conexão e tabelas do banco do sistema,
                         com filtro opcional por TableName.

    Nos dois modos com dados: um result set, uma linha, uma coluna
    NVARCHAR(MAX) por coleção, contendo um array JSON. Coleção vazia = [].
    NULLs são explícitos. Kind foi preservado para identificar as classes.
    Valores sql_variant dos metadados são serializados como texto ou null.

    'all' não retorna linhas de Users, Sessions, Transactions, Operations,
    Values nem Strings. São dados de acesso/execução, não configuração
    do frontend. Suas definições continuam em Tables e Columns.
    Strings (com ConnectionString) é exclusiva do modo específico da API.

    A API deverá ler as colunas JSON da única linha, em substituição aos
    antigos result sets posicionais. Este script não altera a API.
*/
ALTER PROCEDURE [dbo].[Config]
    @SystemName VARCHAR(25),
    @DatabaseName VARCHAR(25) = NULL,
    @TableName VARCHAR(25) = NULL,
    @ReturnValue BIT OUT
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

    DECLARE @ErrorMessage VARCHAR(MAX);
    SET @ReturnValue = 1;

    IF @SystemName IS NULL
        THROW 51000, 'Nome de sistema é requerido.', 1;

    SELECT [D].[Id],
           [D].[DatabaseId],
           [D].[Prefix],
           [D].[Name],
           [D].[Description],
           [D].[MaxRetryLogins],
           [D].[IsActive]
    INTO [#Systems]
    FROM [dbo].[Systems] AS [D]
    WHERE [D].[Name] = @SystemName;
    ALTER TABLE [#Systems] ADD PRIMARY KEY CLUSTERED ([Id]);

    IF NOT EXISTS (SELECT 1 FROM [#Systems])
    BEGIN
        SET @ErrorMessage = 'Sistema "' + @SystemName + '" não cadastrado.';
        THROW 51000, @ErrorMessage, 1;
    END;

    IF EXISTS (SELECT 1 FROM [#Systems] WHERE [IsActive] = 0)
    BEGIN
        SET @ErrorMessage = 'Sistema "' + @SystemName + '" fora do ar.';
        THROW 51000, @ErrorMessage, 1;
    END;

    -- Chamada exclusiva de validação: comportamento original preservado.
    IF @DatabaseName IS NULL
        RETURN 0;

    IF @DatabaseName = 'all'
    BEGIN
        SET @DatabaseName = NULL;
        SET @TableName = NULL;
    END;

    SELECT [D].[Id],
           [D].[ConnectionId],
           [D].[Name],
           [D].[Description]
    INTO [#Databases]
    FROM [dbo].[Databases] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Systems] AS [S] WHERE [S].[DatabaseId] = [D].[Id])
      AND (@DatabaseName IS NULL OR [D].[Name] = @DatabaseName);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Banco de dados do sistema não cadastrado.', 1;
    ALTER TABLE [#Databases] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[DatabaseId],
           [D].[Name],
           [D].[Alias],
           [D].[Description],
           [D].[CurrentId]
    INTO [#Tables]
    FROM [dbo].[Tables] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Databases] AS [P] WHERE [P].[Id] = [D].[DatabaseId])
      AND (@TableName IS NULL OR [D].[Name] = @TableName);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Tabela(s) não cadastrada(s).', 1;
    ALTER TABLE [#Tables] ADD PRIMARY KEY CLUSTERED ([Id]);

    IF NOT EXISTS
    (
        SELECT 1 FROM [dbo].[Connections] AS [C]
        INNER JOIN [#Databases] AS [D] ON [D].[ConnectionId] = [C].[Id]
    )
        THROW 51000, 'Conexão do banco de dados não cadastrada.', 1;

    IF @DatabaseName IS NOT NULL
    BEGIN
        -- Dados de conexão destinados à API. Não enviar este retorno
        -- diretamente ao navegador: Strings contém ConnectionString.
        SELECT
            (
                SELECT 'System' AS [Kind],
                       [D].[Id],
                       [D].[DatabaseId],
                       [D].[Prefix],
                       [D].[Name],
                       [D].[Description],
                       [D].[MaxRetryLogins],
                       [D].[IsActive]
                FROM [#Systems] AS [D]
                ORDER BY [D].[Name], [D].[Id]
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ) AS [System],
            (
                SELECT 'Connection' AS [Kind],
                       [D].[Id],
                       [D].[Name],
                       [D].[Description]
                FROM [dbo].[Connections] AS [D]
                WHERE EXISTS (SELECT 1 FROM [#Databases] AS [P] WHERE [P].[ConnectionId] = [D].[Id])
                ORDER BY [D].[Id]
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ) AS [Connections],
            (
                SELECT 'Database' AS [Kind],
                       [D].[Id],
                       [D].[ConnectionId],
                       [D].[Name],
                       [D].[Description]
                FROM [#Databases] AS [D]
                ORDER BY [D].[Name], [D].[Id]
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ) AS [Databases],
            (
                SELECT 'Table' AS [Kind],
                       [D].[Id],
                       [D].[DatabaseId],
                       [D].[Name],
                       [D].[Alias],
                       [D].[Description],
                       [D].[CurrentId]
                FROM [#Tables] AS [D]
                ORDER BY [D].[DatabaseId], [D].[Name], [D].[Id]
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ) AS [Tables],
            (
                SELECT 'Environment' AS [Kind],
                       [D].[Id],
                       [D].[Sequence],
                       [D].[Name],
                       [D].[Description],
                       [D].[IsRequired]
                FROM [dbo].[Environments] AS [D]
                WHERE EXISTS
                (SELECT 1 FROM [dbo].[Strings] AS [S]
                 INNER JOIN [#Databases] AS [B] ON [B].[ConnectionId] = [S].[ConnectionId]
                 WHERE [S].[EnvironmentId] = [D].[Id])
                ORDER BY [D].[Sequence], [D].[Id]
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ) AS [Environments],
            (
                SELECT 'String' AS [Kind],
                       [D].[Id],
                       [D].[ConnectionId],
                       [D].[EnvironmentId],
                       [D].[Directory],
                       [D].[ConnectionString]
                FROM [dbo].[Strings] AS [D]
                WHERE EXISTS
                (SELECT 1 FROM [#Databases] AS [B] WHERE [B].[ConnectionId] = [D].[ConnectionId])
                ORDER BY [D].[ConnectionId], [D].[EnvironmentId], [D].[Id]
                FOR JSON PATH, INCLUDE_NULL_VALUES
            ) AS [Strings];
        RETURN 0;
    END;

    -- Configuração completa do sistema. As coleções opcionais podem ser vazias.

    SELECT [D].[Id],
           [D].[TableId],
           [D].[DomainId],
           [D].[Sequence],
           [D].[Name],
           [D].[Description],
           [D].[Caption],
           [D].[IsRequired],
           [D].[IsPrimarykey],
           [D].[IsAutoincrement],
           [D].[IsFilterable],
           [D].[IsEditable],
           [D].[IsBrowseable],
           [D].[IsListable],
           [D].[IsEncrypted],
           [D].[IsInWords],
           [D].[IsVirtual]
    INTO [#Columns]
    FROM [dbo].[Columns] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [P] WHERE [P].[Id] = [D].[TableId]);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Colunas de tabelas não cadastradas.', 1;
    ALTER TABLE [#Columns] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[TypeId],
           [D].[Name],
           [D].[Length],
           [D].[Decimals],
           CONVERT(NVARCHAR(MAX), [D].[Default], 126) AS [Default],
           CONVERT(NVARCHAR(MAX), [D].[Minimum], 126) AS [Minimum],
           CONVERT(NVARCHAR(MAX), [D].[Maximum], 126) AS [Maximum],
           [D].[ValidChars],
           [D].[ValidValues],
           [D].[ListValues]
    INTO [#Domains]
    FROM [dbo].[Domains] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Columns] AS [C] WHERE [C].[DomainId] = [D].[Id]);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Domínios de colunas não cadastrados.', 1;
    ALTER TABLE [#Domains] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[CategoryId],
           [D].[Name],
           CONVERT(NVARCHAR(MAX), [D].[Minimum], 126) AS [Minimum],
           CONVERT(NVARCHAR(MAX), [D].[Maximum], 126) AS [Maximum],
           [D].[AskLength],
           [D].[AskDecimals],
           [D].[AskPrimarykey],
           [D].[AskAutoincrement],
           [D].[IsIndexable],
           [D].[IsActive]
    INTO [#Types]
    FROM [dbo].[Types] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Domains] AS [C] WHERE [C].[TypeId] = [D].[Id]);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Tipos de domínios não cadastrados.', 1;
    ALTER TABLE [#Types] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[Name],
           [D].[AskDefault],
           [D].[AskMinimum],
           [D].[AskMaximum],
           [D].[AskInWords],
           [D].[AskMask],
           [D].[AskBrowseable],
           [D].[AskFilterable],
           [D].[AskEncrypted],
           [D].[AskListable]
    INTO [#Categories]
    FROM [dbo].[Categories] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Types] AS [C] WHERE [C].[CategoryId] = [D].[Id]);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Categoria(s) de tipos não cadastrada(s).', 1;
    ALTER TABLE [#Categories] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[SystemId],
           [D].[ParentMenuId],
           [D].[Sequence],
           [D].[Option],
           [D].[Message],
           [D].[Action],
           [D].[IsActive]
    INTO [#Menus]
    FROM [dbo].[Menus] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Systems] AS [P] WHERE [P].[Id] = [D].[SystemId]);
    IF @@ROWCOUNT = 0
        THROW 51000, 'Menu(s) de sistema não cadastrado(s).', 1;
    ALTER TABLE [#Menus] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[TableId],
           [D].[Name],
           [D].[IsUnique]
    INTO [#Indexes]
    FROM [dbo].[Indexes] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [P] WHERE [P].[Id] = [D].[TableId]);
    ALTER TABLE [#Indexes] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[TableId],
           [D].[Name]
    INTO [#Expressions]
    FROM [dbo].[Expressions] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [P] WHERE [P].[Id] = [D].[TableId]);
    ALTER TABLE [#Expressions] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[DomainId],
           [D].[MaskId],
           [D].[CheckDigitModule],
           [D].[CheckDigitFactors],
           [D].[CheckDigitGreaterThanNine]
    INTO [#Maskings]
    FROM [dbo].[Maskings] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Domains] AS [P] WHERE [P].[Id] = [D].[DomainId]);
    ALTER TABLE [#Maskings] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[TableId],
           [D].[Name],
           [D].[IsBefore],
           [D].[IsActive]
    INTO [#Snipers]
    FROM [dbo].[Snipers] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [P] WHERE [P].[Id] = [D].[TableId]);
    ALTER TABLE [#Snipers] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[TableId],
           [D].[Name],
           [D].[Interval],
           [D].[Periodicity],
           [D].[TimeOfDay],
           [D].[DayOfMonth],
           [D].[NextRunDate],
           [D].[IsFirstOrLastDay],
           [D].[IsBusinessDays],
           [D].[IsRunOnce],
           [D].[IsForwardHoliday],
           [D].[Operation],
           [D].[IsActive]
    INTO [#Schedulings]
    FROM [dbo].[Schedulings] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [P] WHERE [P].[Id] = [D].[TableId]);
    ALTER TABLE [#Schedulings] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[TableId],
           [D].[ExpressionId],
           [D].[Name],
           [D].[Operation],
           [D].[IsActive]
    INTO [#Processes]
    FROM [dbo].[Processes] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [P] WHERE [P].[Id] = [D].[TableId]);
    ALTER TABLE [#Processes] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[CategoryId],
           [D].[Name],
           [D].[Description],
           [D].[IsActive]
    INTO [#Properties]
    FROM [dbo].[Properties] AS [D]
    WHERE ISNULL([D].[IsActive], 1) = 1;
    ALTER TABLE [#Properties] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[FkTableId],
           [D].[PkTableId],
           [D].[ListColumnId],
           [D].[Name],
           [D].[IsParentChildren]
    INTO [#References]
    FROM [dbo].[References] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [T] WHERE [T].[Id] IN ([D].[FkTableId], [D].[PkTableId]));
    ALTER TABLE [#References] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[LeftTableId],
           [D].[RightTableId],
           [D].[IsBirectional]
    INTO [#Unicities]
    FROM [dbo].[Unicities] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Tables] AS [T] WHERE [T].[Id] IN ([D].[LeftTableId], [D].[RightTableId]));
    ALTER TABLE [#Unicities] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[SniperId],
           [D].[SchedulingId],
           [D].[ProcessId],
           [D].[Name],
           [D].[Description]
    INTO [#Jobs]
    FROM [dbo].[Jobs] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Snipers] AS [P] WHERE [P].[Id] = [D].[SniperId])
       OR EXISTS (SELECT 1 FROM [#Schedulings] AS [P] WHERE [P].[Id] = [D].[SchedulingId])
       OR EXISTS (SELECT 1 FROM [#Processes] AS [P] WHERE [P].[Id] = [D].[ProcessId]);
    ALTER TABLE [#Jobs] ADD PRIMARY KEY CLUSTERED ([Id]);

    SELECT [D].[Id],
           [D].[JobId],
           [D].[ConnectionId],
           [D].[Sequence],
           [D].[Script]
    INTO [#Scripts]
    FROM [dbo].[Scripts] AS [D]
    WHERE EXISTS (SELECT 1 FROM [#Jobs] AS [P] WHERE [P].[Id] = [D].[JobId]);
    ALTER TABLE [#Scripts] ADD PRIMARY KEY CLUSTERED ([Id]);
    SELECT
        (
            SELECT 'System' AS [Kind],
                   [D].[Id],
                   [D].[DatabaseId],
                   [D].[Prefix],
                   [D].[Name],
                   [D].[Description],
                   [D].[MaxRetryLogins],
                   [D].[IsActive]
            FROM [#Systems] AS [D]
            ORDER BY [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [System],
        (
            SELECT 'Database' AS [Kind],
                   [D].[Id],
                   [D].[ConnectionId],
                   [D].[Name],
                   [D].[Description]
            FROM [#Databases] AS [D]
            ORDER BY [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Databases],
        (
            SELECT 'Table' AS [Kind],
                   [D].[Id],
                   [D].[DatabaseId],
                   [D].[Name],
                   [D].[Alias],
                   [D].[Description],
                   [D].[CurrentId]
            FROM [#Tables] AS [D]
            ORDER BY [D].[DatabaseId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Tables],
        (
            SELECT 'Column' AS [Kind],
                   [D].[Id],
                   [D].[TableId],
                   [D].[DomainId],
                   [D].[Sequence],
                   [D].[Name],
                   [D].[Description],
                   [D].[Caption],
                   [D].[IsRequired],
                   [D].[IsPrimarykey],
                   [D].[IsAutoincrement],
                   [D].[IsFilterable],
                   [D].[IsEditable],
                   [D].[IsBrowseable],
                   [D].[IsListable],
                   [D].[IsEncrypted],
                   [D].[IsInWords],
                   [D].[IsVirtual]
            FROM [#Columns] AS [D]
            ORDER BY [D].[TableId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Columns],
        (
            SELECT 'Domain' AS [Kind],
                   [D].[Id],
                   [D].[TypeId],
                   [D].[Name],
                   [D].[Length],
                   [D].[Decimals],
                   CONVERT(NVARCHAR(MAX), [D].[Default], 126) AS [Default],
                   CONVERT(NVARCHAR(MAX), [D].[Minimum], 126) AS [Minimum],
                   CONVERT(NVARCHAR(MAX), [D].[Maximum], 126) AS [Maximum],
                   [D].[ValidChars],
                   [D].[ValidValues],
                   [D].[ListValues]
            FROM [#Domains] AS [D]
            ORDER BY [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Domains],
        (
            SELECT 'Type' AS [Kind],
                   [D].[Id],
                   [D].[CategoryId],
                   [D].[Name],
                   CONVERT(NVARCHAR(MAX), [D].[Minimum], 126) AS [Minimum],
                   CONVERT(NVARCHAR(MAX), [D].[Maximum], 126) AS [Maximum],
                   [D].[AskLength],
                   [D].[AskDecimals],
                   [D].[AskPrimarykey],
                   [D].[AskAutoincrement],
                   [D].[IsIndexable],
                   [D].[IsActive]
            FROM [#Types] AS [D]
            ORDER BY [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Types],
        (
            SELECT 'Category' AS [Kind],
                   [D].[Id],
                   [D].[Name],
                   [D].[AskDefault],
                   [D].[AskMinimum],
                   [D].[AskMaximum],
                   [D].[AskInWords],
                   [D].[AskMask],
                   [D].[AskBrowseable],
                   [D].[AskFilterable],
                   [D].[AskEncrypted],
                   [D].[AskListable]
            FROM [#Categories] AS [D]
            ORDER BY [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Categories],
        (
            SELECT 'Menu' AS [Kind],
                   [D].[Id],
                   [D].[SystemId],
                   [D].[ParentMenuId],
                   [D].[Sequence],
                   [D].[Option],
                   [D].[Message],
                   [D].[Action],
                   [D].[IsActive]
            FROM [#Menus] AS [D]
            ORDER BY [D].[SystemId], [D].[ParentMenuId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Menus],
        (
            SELECT 'Indexe' AS [Kind],
                   [D].[Id],
                   [D].[TableId],
                   [D].[Name],
                   [D].[IsUnique]
            FROM [#Indexes] AS [D]
            ORDER BY [D].[TableId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Indexes],
        (
            SELECT 'Indexkey' AS [Kind],
                   [D].[Id],
                   [D].[IndexId],
                   [D].[ColumnId],
                   [D].[Sequence],
                   [D].[IsDescending]
            FROM [dbo].[Indexkeys] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Indexes] AS [P] WHERE [P].[Id] = [D].[IndexId])
            ORDER BY [D].[IndexId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Indexkeys],
        (
            SELECT 'Mask' AS [Kind],
                   [D].[Id],
                   [D].[Name],
                   [D].[Mask],
                   [D].[Modificators]
            FROM [dbo].[Masks] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Maskings] AS [M] WHERE [M].[MaskId] = [D].[Id])
            ORDER BY [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Masks],
        (
            SELECT 'Unicity' AS [Kind],
                   [D].[Id],
                   [D].[LeftTableId],
                   [D].[RightTableId],
                   [D].[IsBirectional]
            FROM [#Unicities] AS [D]
            ORDER BY [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Unicities],
        (
            SELECT 'Comparator' AS [Kind],
                   [D].[Id],
                   [D].[Symbol],
                   [D].[Description],
                   [D].[Arity]
            FROM [dbo].[Comparators] AS [D]
            ORDER BY [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Comparators],
        (
            SELECT 'Rule' AS [Kind],
                   [D].[Id],
                   [D].[CategoryId],
                   [D].[ComparatorId]
            FROM [dbo].[Rules] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Categories] AS [P] WHERE [P].[Id] = [D].[CategoryId])
            ORDER BY [D].[CategoryId], [D].[ComparatorId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Rules],
        (
            SELECT 'Expression' AS [Kind],
                   [D].[Id],
                   [D].[TableId],
                   [D].[Name]
            FROM [#Expressions] AS [D]
            ORDER BY [D].[TableId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Expressions],
        (
            SELECT 'Condition' AS [Kind],
                   [D].[Id],
                   [D].[ExpressionId],
                   [D].[Sequence],
                   [D].[Connector],
                   [D].[LeftParenthesis],
                   [D].[LeftColumnId],
                   [D].[ComparatorId],
                   [D].[RightColumnId],
                   CONVERT(NVARCHAR(MAX), [D].[Value], 126) AS [Value],
                   [D].[RightParenthesis]
            FROM [dbo].[Conditions] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Expressions] AS [P] WHERE [P].[Id] = [D].[ExpressionId])
            ORDER BY [D].[ExpressionId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Conditions],
        (
            SELECT 'Property' AS [Kind],
                   [D].[Id],
                   [D].[CategoryId],
                   [D].[Name],
                   [D].[Description],
                   [D].[IsActive]
            FROM [#Properties] AS [D]
            ORDER BY [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Properties],
        (
            SELECT 'Behavior' AS [Kind],
                   [D].[Id],
                   [D].[ColumnId],
                   [D].[ExpressionId],
                   [D].[PropertyId],
                   CONVERT(NVARCHAR(MAX), [D].[Value], 126) AS [Value],
                   CONVERT(NVARCHAR(MAX), [D].[ElseValue], 126) AS [ElseValue]
            FROM [dbo].[Behaviors] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Columns] AS [P] WHERE [P].[Id] = [D].[ColumnId])
              AND EXISTS (SELECT 1 FROM [#Expressions] AS [P] WHERE [P].[Id] = [D].[ExpressionId])
              AND EXISTS (SELECT 1 FROM [#Properties] AS [P] WHERE [P].[Id] = [D].[PropertyId])
            ORDER BY [D].[ColumnId], [D].[ExpressionId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Behaviors],
        (
            SELECT 'Reference' AS [Kind],
                   [D].[Id],
                   [D].[FkTableId],
                   [D].[PkTableId],
                   [D].[ListColumnId],
                   [D].[Name],
                   [D].[IsParentChildren]
            FROM [#References] AS [D]
            ORDER BY [D].[FkTableId], [D].[PkTableId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [References],
        (
            SELECT 'Referencekey' AS [Kind],
                   [D].[Id],
                   [D].[ReferenceId],
                   [D].[FkColumnId],
                   [D].[Sequence]
            FROM [dbo].[Referencekeys] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#References] AS [P] WHERE [P].[Id] = [D].[ReferenceId])
            ORDER BY [D].[ReferenceId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Referencekeys],
        (
            SELECT 'Connection' AS [Kind],
                   [D].[Id],
                   [D].[Name],
                   [D].[Description]
            FROM [dbo].[Connections] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Databases] AS [B] WHERE [B].[ConnectionId] = [D].[Id])
               OR EXISTS (SELECT 1 FROM [#Scripts] AS [S] WHERE [S].[ConnectionId] = [D].[Id])
            ORDER BY [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Connections],
        (
            SELECT 'Environment' AS [Kind],
                   [D].[Id],
                   [D].[Sequence],
                   [D].[Name],
                   [D].[Description],
                   [D].[IsRequired]
            FROM [dbo].[Environments] AS [D]
            ORDER BY [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Environments],
        (
            SELECT 'Engine' AS [Kind],
                   [D].[Id],
                   [D].[Name],
                   [D].[Provider],
                   [D].[PackageName],
                   [D].[PackageVersion],
                   [D].[Directory],
                   [D].[IsActive]
            FROM [dbo].[Engines] AS [D]
            WHERE EXISTS (SELECT 1 FROM [dbo].[Mappings] AS [M] INNER JOIN [#Types] AS [T] ON [T].[Id] = [M].[TypeId] WHERE [M].[EngineId] = [D].[Id])
            ORDER BY [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Engines],
        (
            SELECT 'Mapping' AS [Kind],
                   [D].[Id],
                   [D].[EngineId],
                   [D].[TypeId],
                   [D].[Name],
                   [D].[Length],
                   [D].[Decimals],
                   [D].[Complement]
            FROM [dbo].[Mappings] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Types] AS [P] WHERE [P].[Id] = [D].[TypeId])
            ORDER BY [D].[EngineId], [D].[TypeId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Mappings],
        (
            SELECT 'Masking' AS [Kind],
                   [D].[Id],
                   [D].[DomainId],
                   [D].[MaskId],
                   [D].[CheckDigitModule],
                   [D].[CheckDigitFactors],
                   [D].[CheckDigitGreaterThanNine]
            FROM [#Maskings] AS [D]
            ORDER BY [D].[DomainId], [D].[MaskId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Maskings],
        (
            SELECT 'Include' AS [Kind],
                   [D].[Id],
                   [D].[IndexId],
                   [D].[ColumnId]
            FROM [dbo].[Includes] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Indexes] AS [P] WHERE [P].[Id] = [D].[IndexId])
            ORDER BY [D].[IndexId], [D].[ColumnId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Includes],
        (
            SELECT 'Unicitykey' AS [Kind],
                   [D].[Id],
                   [D].[UnicityId],
                   [D].[LeftColumnId],
                   [D].[RightColumnId]
            FROM [dbo].[Unicitykeys] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Unicities] AS [P] WHERE [P].[Id] = [D].[UnicityId])
            ORDER BY [D].[UnicityId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Unicitykeys],
        (
            SELECT 'Permission' AS [Kind],
                   [D].[Id],
                   [D].[SystemId],
                   [D].[UserId],
                   [D].[TableId],
                   [D].[CanCreate],
                   [D].[CanRead],
                   [D].[CanUpdate],
                   [D].[CanDelete]
            FROM [dbo].[Permissions] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Systems] AS [P] WHERE [P].[Id] = [D].[SystemId])
            ORDER BY [D].[SystemId], [D].[UserId], [D].[TableId], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Permissions],
        (
            SELECT 'Sniper' AS [Kind],
                   [D].[Id],
                   [D].[TableId],
                   [D].[Name],
                   [D].[IsBefore],
                   [D].[IsActive]
            FROM [#Snipers] AS [D]
            ORDER BY [D].[TableId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Snipers],
        (
            SELECT 'Scheduling' AS [Kind],
                   [D].[Id],
                   [D].[TableId],
                   [D].[Name],
                   [D].[Interval],
                   [D].[Periodicity],
                   [D].[TimeOfDay],
                   [D].[DayOfMonth],
                   [D].[NextRunDate],
                   [D].[IsFirstOrLastDay],
                   [D].[IsBusinessDays],
                   [D].[IsRunOnce],
                   [D].[IsForwardHoliday],
                   [D].[Operation],
                   [D].[IsActive]
            FROM [#Schedulings] AS [D]
            ORDER BY [D].[TableId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Schedulings],
        (
            SELECT 'Process' AS [Kind],
                   [D].[Id],
                   [D].[TableId],
                   [D].[ExpressionId],
                   [D].[Name],
                   [D].[Operation],
                   [D].[IsActive]
            FROM [#Processes] AS [D]
            ORDER BY [D].[TableId], [D].[Name], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Processes],
        (
            SELECT 'Job' AS [Kind],
                   [D].[Id],
                   [D].[SniperId],
                   [D].[SchedulingId],
                   [D].[ProcessId],
                   [D].[Name],
                   [D].[Description]
            FROM [#Jobs] AS [D]
            ORDER BY [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Jobs],
        (
            SELECT 'Script' AS [Kind],
                   [D].[Id],
                   [D].[JobId],
                   [D].[ConnectionId],
                   [D].[Sequence],
                   [D].[Script]
            FROM [#Scripts] AS [D]
            ORDER BY [D].[JobId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Scripts],
        (
            SELECT 'Link' AS [Kind],
                   [D].[Id],
                   [D].[JobId],
                   [D].[Sequence],
                   [D].[Method],
                   [D].[URL]
            FROM [dbo].[Links] AS [D]
            WHERE EXISTS (SELECT 1 FROM [#Jobs] AS [P] WHERE [P].[Id] = [D].[JobId])
            ORDER BY [D].[JobId], [D].[Sequence], [D].[Id]
            FOR JSON PATH, INCLUDE_NULL_VALUES
        ) AS [Links];

    RETURN 0;
END;
GO

/* Testes manuais (executar separadamente, após aplicar a procedure):

DECLARE @ReturnValue BIT;

-- Validação: não deve produzir result set.
EXEC [dbo].[Config] @SystemName = 'crudex', @ReturnValue = @ReturnValue OUTPUT;

-- Configuração: uma linha, uma coluna JSON por coleção.
EXEC [dbo].[Config] @SystemName = 'crudex', @DatabaseName = 'all',
    @ReturnValue = @ReturnValue OUTPUT;

-- Conexão para a API: uma linha, seis colunas JSON.
EXEC [dbo].[Config] @SystemName = 'crudex', @DatabaseName = 'crudex',
    @TableName = 'Categories', @ReturnValue = @ReturnValue OUTPUT;

-- Também testar: sistema inexistente/inativo, banco incorreto e tabela inexistente.
*/
