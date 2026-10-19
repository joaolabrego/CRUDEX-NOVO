#nullable enable

using System;
using System.IO;
using System.Net.WebSockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Crudex;

/// <summary>Uma conexão com uma instância do frontend. Mensagens são valores JSON.</summary>
public sealed class Intercom : IDisposable
{
    private readonly WebSocket _socket;
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private int _listening;

    public Func<JsonElement, Task>? OnMessage { get; set; }
    public Func<Task>? OnClosed { get; set; }

    public bool IsOpen => _socket.State == WebSocketState.Open;

    // A conexão deve ter sido aceita pela rota, após suas validações.
    // A partir daqui, o Intercom é responsável por descartá-la.
    public Intercom(WebSocket socket)
    {
        _socket = socket ?? throw new ArgumentNullException(nameof(socket));
    }

    /// <summary>Executar uma única vez e aguardar até a conexão terminar.</summary>
    public async Task ListenAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _listening, 1) != 0)
            throw new InvalidOperationException("O Intercom já foi colocado em escuta.");

        var buffer = new byte[4096];

        try
        {
            while (_socket.State is WebSocketState.Open or WebSocketState.CloseSent)
            {
                using var content = new MemoryStream();
                WebSocketReceiveResult received;

                do
                {
                    received = await _socket.ReceiveAsync(
                        new ArraySegment<byte>(buffer), cancellationToken);

                    if (received.MessageType == WebSocketMessageType.Close)
                    {
                        await CloseAsync(cancellationToken);
                        return;
                    }

                    if (received.MessageType != WebSocketMessageType.Text)
                    {
                        await CloseAsync(cancellationToken,
                            WebSocketCloseStatus.InvalidMessageType,
                            "O Intercom recebe apenas mensagens JSON de texto.");
                        return;
                    }

                    content.Write(buffer, 0, received.Count);
                }
                while (!received.EndOfMessage);

                using var document = JsonDocument.Parse(content.ToArray());
                var handler = OnMessage;

                if (handler != null)
                    await handler(document.RootElement.Clone());
            }
        }
        finally
        {
            Dispose();
            var handler = OnClosed;

            if (handler != null)
                await handler();
        }
    }

    public async Task SendAsync(object? message,
        CancellationToken cancellationToken = default)
    {
        var content = JsonSerializer.SerializeToUtf8Bytes(message);

        await _sendLock.WaitAsync(cancellationToken);

        try
        {
            if (!IsOpen)
                throw new InvalidOperationException("O Intercom não está conectado.");

            await _socket.SendAsync(new ArraySegment<byte>(content),
                WebSocketMessageType.Text, true, cancellationToken);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    // Envia o fechamento; ListenAsync recebe a confirmação do outro lado.
    // CloseOutputAsync evita iniciar uma segunda leitura concorrente.
    public async Task CloseAsync(CancellationToken cancellationToken = default,
        WebSocketCloseStatus status = WebSocketCloseStatus.NormalClosure,
        string reason = "")
    {
        await _sendLock.WaitAsync(cancellationToken);

        try
        {
            if (_socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                await _socket.CloseOutputAsync(status, reason, cancellationToken);
        }
        finally
        {
            _sendLock.Release();
        }
    }

    // Interrompe também uma leitura pendente. Para saída normal, use CloseAsync.
    public void Dispose()
    {
        _socket.Dispose();
    }
}
