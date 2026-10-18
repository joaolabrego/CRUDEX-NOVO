IF(SELECT object_id('[dbo].[Config]', 'P')) IS NULL
	EXEC('CREATE PROCEDURE [dbo].[Config] AS PRINT 1')
GO
ALTER PROCEDURE [dbo].[Config](@SystemName VARCHAR(25)
							  ,@EnvironmentName VARCHAR(25) = NULL
							  ,@TableName VARCHAR(25) = NULL) AS
BEGIN
	SET NOCOUNT ON
	SET TRANSACTION ISOLATION LEVEL READ COMMITTED
	DECLARE @ErrorMessage VARCHAR(MAX)

	SET @ReturnValue = 1
	IF @SystemName IS NULL BEGIN
		SET @ErrorMessage = 'Nome de sistema é requerido.';
		THROW 51000, @ErrorMessage, 1
	END
	-- 0 [System]
	SELECT 	'System' AS [Kind]
			,[Id]
			,[DatabaseId]
			,[Prefix]
			,[Name]
			,[Description]
			,[MaxRetryLogins]
			,[IsOffAir]
			,[IsActive]
		INTO [#System]
		FROM [dbo].[Systems]
		WHERE [Name] = @SystemName
	IF @@ROWCOUNT = 0 BEGIN
		SET @ErrorMessage = 'Sistema "' + @SystemName + '" não cadastrado.';
		THROW 51000, @ErrorMessage, 1
	END
	IF (SELECT [IsActive] FROM [#System]) = 0 BEGIN
		SET @ErrorMessage = CONCAT('Sistema "', @SystemName,  '" inativo.');
		THROW 51000, @ErrorMessage, 1
	END
	IF (SELECT [IsOffAir] FROM [#System]) = 1 BEGIN
		SET @ErrorMessage = CONCAT('Sistema "', @SystemName, '" fora do ar.');
		THROW 51000, @ErrorMessage, 1
	END
	IF @EnvironmentName IS NULL
		RETURN 0
	IF @EnvironmentName = 'all' BEGIN
		SET @EnvironmentName = NULL
		SET @TableName = NULL
	END
	-- 1 [Database]
	SELECT 	'Database' AS [Kind]
			,[Id]
			,[ConnectionId]
			,[Name]
			,[Description]
		INTO [#Database]
		FROM [dbo].[Databases] [D]
			INNER JOIN [#Systems] [S] ON [S].[DatabaseId] = [D].[Id]
	IF @@ROWCOUNT = 0 BEGIN
		SET @ErrorMessage = CONCAT('Banco-de-dados do sistema "', @SystemName, '" não cadastrado(s).');
		THROW 51000, @ErrorMessage, 1
	END
	
	DECLARE @DatabaseName VARCHAR(25) = (SELECT [Name] FROM [#Database])

	-- 2 [Connection]
	SELECT  'Connection' AS [Kind]
			,[C].[Id]
			,[C].[Name]
			,[C].[Description]
		INTO [#Connections]
		FROM [dbo].[Connections] [C]
			INNER JOIN [#Database] [D] ON [D].[ConnectionId] = [C].[Id]
	IF @@ROWCOUNT = 0 BEGIN
		SET @ErrorMessage = CONCAT('Conexão do banco-de-dados "', @DatabaseName, '" não cadastrada.');
		THROW 51000, @ErrorMessage, 1
	END
	-- 3 [Environment]
	SELECT	[Id]
			,[Sequence]
			,[Name]
			,[Description]
			,[IsRequired]
		INTO [#Environments]
 		FROM [Environments]
		WHERE @EnvironmentName IS NULL OR [Name] = @EnvironmentName
	IF @@ROWCOUNT = 0 BEGIN
		SET @ErrorMessage = CONCAT('Ambiente "', @EnvironmentName, '" não cadastrado.');
		THROW 51000, @ErrorMessage, 1
	END
	-- 3 [StringConnections]
	SELECT	[S].[Id]
			,[S].[ConnectionId]
			,[S].[EnvironmentId]
			,[S].[Directory]
			,[S].[ConnectionString]
		INTO [#String]
		FROM [Strings] [S]
			INNER JOIN [#Connections] [C] ON [C].[Id] = [S].[ConnectionId]
			INNER JOIN [#Environments] [E] ON [E].[Id] = [S].[EnvironmentId]
	IF @@ROWCOUNT = 0 BEGIN
		SET @ErrorMessage = CONCAT('ConnectionString do banco-de-dados "', @DatabaseName, '" não cadastrado.');
		THROW 51000, @ErrorMessage, 1
	END
	-- 4 [Tables]
	SELECT	'Table' AS [Kind]
			,[Id]
			,[DatabaseId]
			,[Name]
			,[Alias]
			,[Description]
			,[CurrentId]
		INTO [#Tables]
		FROM [dbo].[Tables] [T]
			INNER JOIN [#Databases] [D] ON [D].[Id] = [T].[DatabaseId]
		WHERE @TableName IS NULL OR [T].[Name] = @TableName
	IF @@ROWCOUNT = 0 BEGIN
		SET @ErrorMessage = CONCAT('Tabelas do banco-de-dados "', @DatabaseName, '" não cadastrada(s).');
		THROW 51000, @ErrorMessage, 1
	END
	ALTER TABLE [#Tables] ADD PRIMARY KEY CLUSTERED([Id])

	IF @EnvironmentName IS NULL BEGIN
		-- 4 [Columns]
		SELECT	'Column' AS [Kind]
				,[Id]
				,[TableId]
				,[DomainId]
				,[Sequence]
				,[Name]
				,[Description]
				,[Caption]
				,[IsRequired]
				,[IsPrimarykey]
				,[IsAutoincrement]
				,[IsFilterable]
				,[IsEditable]
				,[IsBrowseable]
				,[IsListable]
				,[IsEncrypted]
				,[IsInWords]
				,[IsVirtual]
			INTO [#Columns]
			FROM [dbo].[Columns] [C]
				INNER JOIN [#Tables] [T] ON [T].[Id]= [C].[TableId] 
		IF @@ROWCOUNT = 0 BEGIN
			SET @ErrorMessage = CONCAT('Colunas de tabelas do banco-de-dados "', @DatabaseName, '" não cadastradas.');
			THROW 51000, @ErrorMessage, 1
		END
		ALTER TABLE [#Columns] ADD PRIMARY KEY CLUSTERED([Id])
		CREATE INDEX [#ColumnsDomainId] ON [#Columns]([DomainId])

		-- 5 [Domains]
		SELECT	'Domain' AS [Kind]
				,[D].[Id]
				,[D].[TypeId]
				,[D].[Name]
				,[D].[Length]
				,[D].[Decimals]
				,[D].[Default]
				,[D].[Minimum]
				,[D].[Maximum]
				,[D].[ValidChars]
				,[D].[ValidValues]
				,[D].[ListValues
			INTO [#Domains]
			FROM [dbo].[Domains] [D]
			WHERE EXISTS(SELECT TOP 1 1 FROM [#Columns] WHERE [DomainId] = [D].[Id])
		IF @@ROWCOUNT = 0 BEGIN
			SET @ErrorMessage = CONCAT('Domínios de colunas de tabela do banco-de-dados "', @DatabaseName, '" não cadastrados.');
			THROW 51000, @ErrorMessage, 1
		END
		ALTER TABLE [#Domains] ADD PRIMARY KEY NONCLUSTERED([Id])
		CREATE INDEX [#DomainsTypeId] ON [#Domains]([TypeId])

		-- 6 [Types]
		SELECT 	'Type' AS [Kind]
				,[T].[Id]
				,[T].[CategoryId]
				,[T].[Name]
				,[T].[MaxLength]
				,[T].[Minimum]
				,[T].[Maximum]
				,[T].[AskLength]
				,[T].[AskDecimals]
				,[T].[AskPrimarykey]
				,[T].[AskAutoincrement]
				,[T].[AskFilterable]
				,[T].[AskGridable]
				,[T].[AskCodification]
				,[T].[IsActive]
			INTO [#Types]
			FROM [dbo].[Types] [T]
			WHERE EXISTS(SELECT TOP 1 1 FROM [#Domains] WHERE [TypeId] = [T].[Id])
		IF @@ROWCOUNT = 0
			THROW 51000, 'Tipos de domínios não cadastrados.', 1
		CREATE INDEX [#TypesCategoryId] ON [#Types]([CategoryId])

		-- 7 [Categories]
		SELECT 	'Category' AS [Kind]
				,[C].[Id]
				,[C].[Name]
				,[C].[AskEncrypted]
				,[C].[AskMask]
				,[C].[AskListable]
				,[C].[AskDefault]
				,[C].[AskMinimum]
				,[C].[AskMaximum]
				,[C].[AskInWords]
			INTO [#Categories]
			FROM [dbo].[Categories] [C]
			WHERE EXISTS(SELECT TOP 1 1 FROM [#Types] WHERE [CategoryId] = [C].[Id])
		IF @@ROWCOUNT = 0
			THROW 51000, 'Categoria(s) de tipos não cadastrada(s).', 1

		-- 8 [Menus]
		SELECT 	'Menu' AS [Kind]
				,[M].[Id]
				,[M].[SystemId]
				,[M].[Sequence]
				,[M].[Caption]
				,[M].[Message]
				,[M].[Action]
				,[M].[ParentMenuId]
			INTO [#Menus]
			FROM [dbo].[Menus] [M]
				INNER JOIN [#Systems] [S] ON [S].[Id] = [M].[SystemId]
		IF @@ROWCOUNT = 0
			THROW 51000, 'Menu(s) de sistema não cadastrado(s).', 1

		-- 9 [Indexes]
		SELECT 	'Index' AS [Kind]
				,[I].[Id]
				,[I].[TableId]
				,[I].[Name]
				,[I].[IsUnique]
			INTO [#Indexes]
			FROM [dbo].[Indexes] [I]
				INNER JOIN [#Tables] [T] ON [T].[Id] = [I].[TableId]
		ALTER TABLE [#Indexes] ADD PRIMARY KEY NONCLUSTERED([Id])

		-- 10 [Indexkeys]
		SELECT 	'Indexkey' AS [Kind]
				,[IK].[Id]
				,[IK].[IndexId]
				,[IK].[Sequence]
				,[IK].[ColumnId]
				,[IK].[IsDescending]
			INTO [#Indexkeys]
			FROM [dbo].[Indexkeys] [IK]
				INNER JOIN [#Indexes] [I] ON [I].[Id] = [IK].IndexId
			
		-- 11 [Masks]
		SELECT 	'Mask' AS [Kind]
				,[M].[Id]
				,[M].[Name]
				,[M].[Mask]
			INTO [#Masks]
			FROM [dbo].[Masks] [M]
			WHERE EXISTS(SELECT TOP 1 1 FROM [#Domains] WHERE [MaskId] = [M].[Id])
			
		-- 12 [Unicities]
		SELECT 'Unicity' AS [Kind]
				,[U].[Id]
				,[U].[ColumnId1]
				,[U].[ColumnId2]
				,[U].[IsBidirectional]
			INTO [#Unicities]
			FROM [dbo].[Unicities] [U]
			WHERE EXISTS(SELECT 1 FROM [dbo].[#Columns] WHERE [Id] IN ([U].[ColumnId1], [U].[ColumnId2]))
		-- 12 [Comparators]
		SELECT 'Comparator' AS [Kind]
				,[Id]
				,[Symbol]
				,[Description]
				,[Arity]
			INTO [#Comparators]
			FROM [dbo].[Comparators]

		-- 13 [Rules]
		SELECT 'Rule' AS [Kind]
				,[Id]
				,[CategoryId]
				,[ComparatorId]
			INTO [#Rules]
			FROM [dbo].[Rules]

		-- 14 [Expressions]
		SELECT 'Expression' AS [Kind]
				,[E].[Id]
				,[E].[TableId]
				,[E].[Name]
			INTO [#Expressions]
			FROM [dbo].[Expressions] [E]
			WHERE EXISTS(SELECT 1 FROM [#Tables] [T] WHERE [T].[Id] = [E].[TableId])

		-- 15 [Conditions]
		SELECT 'Condition' AS [Kind]
				,[C].[Id]
				,[C].[ExpressionId]
				,[C].[Sequence]
				,[C].[Connector]
				,[C].[LeftParenthesis]
				,[C].[LeftColumnId]
				,[C].[ComparatorId]
				,[C].[RightColumnId]
				,[C].[RightValues]
				,[C].[RightParenthesis]
			INTO [#Conditions]
			FROM [dbo].[Conditions] [C]
			WHERE EXISTS(SELECT 1 FROM [#Expressions] [E] WHERE [E].[Id] = [C].[ExpressionId])

		-- 16 [Properties]
		SELECT 'Property' AS [Kind]
				,[P].[Id]
				,[P].[Name]
				,[P].[CategoryId]
				,[P].[Description]
				,[P].[IsActive]
			INTO [#Properties]
			FROM [dbo].[Properties] [P]
			WHERE ISNULL([P].[IsActive], 1) = 1

		-- 17 [Behaviors]
		SELECT 'Behavior' AS [Kind]
				,[B].[Id]
				,[B].[ColumnId]
				,[B].[ExpressionId]
				,[B].[PropertyId]
				,[B].[Value]
				,[B].[ElseValue]
			INTO [#Behaviors]
			FROM [dbo].[Behaviors] [B]
			WHERE EXISTS(SELECT 1 FROM [#Columns] [C] WHERE [C].[Id] = [B].[ColumnId])
				AND EXISTS(SELECT 1 FROM [#Expressions] [E] WHERE [E].[Id] = [B].[ExpressionId])
				AND EXISTS(SELECT 1 FROM [#Properties] [P] WHERE [P].[Id] = [B].[PropertyId])

		-- 18 [References]
		SELECT 'Reference' AS [Kind]
				,[R].[Id]
				,[R].[FkTableId]
				,[R].[PkTableId]
				,[R].[Name]
				,[R].[IsParentChildren] AS [IsParentChild]
			INTO [#References]
			FROM [dbo].[References] [R]
			WHERE EXISTS(SELECT 1 FROM [#Tables] [T] WHERE [T].[Id] IN ([R].[FkTableId], [R].[PkTableId]))

		-- 19 [Referencekeys]
		SELECT 'Referencekey' AS [Kind]
				,[RK].[Id]
				,[RK].[ReferenceId]
				,[RK].[FkColumnId]
				,[RK].[Sequence]
			INTO [#Referencekeys]
			FROM [dbo].[Referencekeys] [RK]
			WHERE EXISTS(SELECT 1 FROM [#References] [R] WHERE [R].[Id] = [RK].[ReferenceId])
	END

	-- Results
	SELECT * FROM [#Systems] ORDER BY [Name] -- 0 [#Systems]
	IF @DatabaseName IS NULL BEGIN
		SELECT * FROM [#Databases] ORDER BY [Name] -- 1 [#Databases]
		SELECT * FROM [#Tables] ORDER BY [DatabaseId], [Name] -- 2 [#Tables]
		SELECT * FROM [#Columns] ORDER BY [TableId], [Sequence] -- 3 [#Columns]
		SELECT * FROM [#Domains] ORDER BY [Name] -- 4 [#Domains]
		SELECT * FROM [#Types] ORDER BY [Name] -- 5 [#Types]
		SELECT * FROM [#Categories] ORDER BY [Name] -- 6 [#Categories]
		SELECT * FROM [#Menus] ORDER BY [SystemId], [Sequence] -- 7 [#Menus]
		SELECT * FROM [#Indexes] ORDER BY [Name] -- 8 [#Indexes]
		SELECT * FROM [#Indexkeys] ORDER BY [IndexId], [Sequence] -- 9 [#Indexkeys]
		SELECT * FROM [#Masks] ORDER BY [Id] -- 10 [#Masks]
		SELECT * FROM [#Unicities] ORDER BY [Id] -- 11 [#Unicities]
		SELECT * FROM [#Comparators] ORDER BY [Id] -- 12 [#Comparators]
		SELECT * FROM [#Rules] ORDER BY [CategoryId], [ComparatorId] -- 13 [#Rules]
		SELECT * FROM [#Expressions] ORDER BY [TableId], [Name] -- 14 [#Expressions]
		SELECT * FROM [#Conditions] ORDER BY [ExpressionId], [Sequence] -- 15 [#Conditions]
		SELECT * FROM [#Properties] ORDER BY [Name] -- 16 [#Properties]
		SELECT * FROM [#Behaviors] ORDER BY [ColumnId], [ExpressionId] -- 17 [#Behaviors]
		SELECT * FROM [#References] ORDER BY [FkTableId], [PkTableId], [Name] -- 18 [#References]
		SELECT * FROM [#Referencekeys] ORDER BY [ReferenceId], [Sequence] -- 19 [#Referencekeys]
	END ELSE BEGIN
		SELECT * FROM [#Connections] ORDER BY [Id] -- 1 [#Connections]]
		SELECT * FROM [#Databases] ORDER BY [Name] -- 2 [#Databases]
		SELECT * FROM [#Tables] ORDER BY [DatabaseId], [Name] -- 3 [#Tables]
	END
END
GO
