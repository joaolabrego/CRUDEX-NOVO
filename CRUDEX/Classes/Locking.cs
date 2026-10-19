#nullable enable

using Microsoft.Data.Sqlite;
using System.Data;
using System.Text.Json;

namespace Crudex;

/// <summary>
/// Armazena reservas em SQLite em memória e associa seus proprietários ao Intercom.
/// Manter UMA instância desta classe para a API inteira (AddSingleton).
/// Este primeiro passo ainda não implementa a decisão de conflito entre reservas.
/// </summary>
public sealed class Locking : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly Lock _sync = new();
    private readonly Dictionary<string, (Intercom Intercom, long LoginId)> _intercoms = new();
    private bool _disposed;

    public Locking()
    {
        // Não fechar entre operações: esta conexão mantém o banco vivo.
        _connection = new SqliteConnection("Data Source=:memory:;Pooling=False");

        try
        {
            _connection.Open();

            using var command = _connection.CreateCommand();
            command.CommandText = @"
                CREATE TABLE Lockings
                (
                    Id            INTEGER PRIMARY KEY,
                    IntercomId    TEXT    NOT NULL,
                    LoginId       INTEGER NOT NULL,
                    TransactionId INTEGER NULL,
                    DatabaseId    INTEGER NOT NULL,
                    TableId       INTEGER NULL,
                    RecordId      TEXT    NULL,
                    CHECK (RecordId IS NULL OR TableId IS NOT NULL)
                );

                CREATE INDEX IX_Lockings_IntercomId
                    ON Lockings (IntercomId);

                CREATE INDEX IX_Lockings_Resource
                    ON Lockings (DatabaseId, TableId, RecordId);
            ";
            command.ExecuteNonQuery();
        }
        catch
        {
            _connection.Dispose();
            throw;
        }
    }

    /// <summary>
    /// Associa uma conexão ao login JÁ validado pela API.
    /// O identificador retornado pertence à conexão, não à máquina ou navegador.
    /// Chamar uma vez por Intercom, não a cada mensagem.
    /// </summary>
    public string Attach(Intercom intercom, long loginId)
    {
        ArgumentNullException.ThrowIfNull(intercom);

        lock (_sync)
        {
            EnsureAvailable();

            foreach (var item in _intercoms)
                if (ReferenceEquals(item.Value.Intercom, intercom))
                    throw new InvalidOperationException(
                        "O Intercom já está associado.");

            var intercomId = Guid.NewGuid().ToString("N");
            _intercoms.Add(intercomId, (intercom, loginId));

            intercom.OnClosed = () =>
            {
                // Acrescentaremos aqui:
                // 1. Cancelamento das transações pendentes.
                // 2. Encerramento do login correspondente.

                Detach(intercomId);

                return Task.CompletedTask;
            };

            return intercomId;
        }
    }

    /// <summary>
    /// Persiste uma reserva cuja aquisição já foi autorizada pelo executor.
    /// NÃO é um TryLock: não verifica conflitos com outras reservas.
    /// TableId/RecordId nulos = banco; apenas RecordId nulo = tabela;
    /// ambos preenchidos = registro. RecordId deve ser uma chave canônica.
    /// </summary>
    public long Store(string intercomId, JsonElement parameters)
    {
        long databaseId = parameters.GetProperty("DatabaseId").GetInt64();

        long? tableId =
            parameters.TryGetProperty("TableId", out var table) &&
            table.ValueKind != JsonValueKind.Null
                ? table.GetInt64()
                : null;

        string? recordId =
            parameters.TryGetProperty("RecordId", out var record)
                ? record.GetString()
                : null;

        long? transactionId =
            parameters.TryGetProperty("TransactionId", out var transaction) &&
            transaction.ValueKind != JsonValueKind.Null
                ? transaction.GetInt64()
                : null;

        lock (_sync)
        {
            EnsureAvailable();

            if (!_intercoms.TryGetValue(intercomId, out var owner))
                throw new InvalidOperationException("Intercom não associado.");

            using var command = _connection.CreateCommand();
            command.CommandText = @"
            INSERT INTO Lockings
                (IntercomId, LoginId, TransactionId, DatabaseId, TableId, RecordId)
            VALUES
                ($intercomId, $loginId, $transactionId, $databaseId, $tableId, $recordId);
            SELECT last_insert_rowid();
        ";

            command.Parameters.AddWithValue("$intercomId", intercomId);
            command.Parameters.AddWithValue("$loginId", owner.LoginId);
            command.Parameters.AddWithValue("$transactionId", (object?)transactionId ?? DBNull.Value);
            command.Parameters.AddWithValue("$databaseId", databaseId);
            command.Parameters.AddWithValue("$tableId", (object?)tableId ?? DBNull.Value);
            command.Parameters.AddWithValue("$recordId", (object?)recordId ?? DBNull.Value);

            return Convert.ToInt64(command.ExecuteScalar());
        }
    }

    /// <summary>Remove somente a reserva pertencente à conexão informada.</summary>
    public bool Remove(string intercomId, long lockingId)
    {
        lock (_sync)
        {
            EnsureAvailable();

            using var command = _connection.CreateCommand();
            command.CommandText = @"
                DELETE FROM Lockings
                WHERE Id = $id AND IntercomId = $intercomId;
            ";
            command.Parameters.AddWithValue("$id", lockingId);
            command.Parameters.AddWithValue("$intercomId", intercomId);
            return command.ExecuteNonQuery() != 0;
        }
    }

    /// <summary>Devolve uma cópia dos registros para consulta pelo executor.</summary>
    public DataTable GetLockings()
    {
        lock (_sync)
        {
            EnsureAvailable();

            using var command = _connection.CreateCommand();
            command.CommandText = @"
                SELECT Id, IntercomId, LoginId, TransactionId, DatabaseId, TableId, RecordId
                FROM Lockings
                ORDER BY Id;
            ";
            using var reader = command.ExecuteReader();
            var table = new DataTable("Lockings");
            table.Load(reader);
            return table;
        }
    }

    /// <summary>Envia uma mensagem JSON somente à conexão indicada.</summary>
    public Task NotifyAsync(string intercomId, object? message,
        CancellationToken cancellationToken = default)
    {
        Intercom intercom;

        lock (_sync)
        {
            EnsureAvailable();

            if (!_intercoms.TryGetValue(intercomId, out var owner))
                throw new InvalidOperationException("Intercom não associado.");

            intercom = owner.Intercom;
        }

        // Aguardar a rede fora da região que protege a conexão SQLite.
        return intercom.SendAsync(message, cancellationToken);
    }

    /// <summary>
    /// Libera as reservas dessa conexão e remove sua associação.
    /// O executor deve cancelar as transações correspondentes ANTES desta chamada.
    /// Não altera logins, transações ou reservas de outras conexões.
    /// </summary>
    public int Detach(string intercomId)
    {
        lock (_sync)
        {
            EnsureAvailable();

            using var command = _connection.CreateCommand();
            command.CommandText = "DELETE FROM Lockings WHERE IntercomId = $intercomId;";
            command.Parameters.AddWithValue("$intercomId", intercomId);
            var removed = command.ExecuteNonQuery();

            _intercoms.Remove(intercomId);
            return removed;
        }
    }

    private void EnsureAvailable()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
                return;

            _disposed = true;
            _connection.Dispose();
            _intercoms.Clear();
        }
    }
}
