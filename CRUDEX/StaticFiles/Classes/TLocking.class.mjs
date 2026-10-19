"use strict";

/** Cliente de Locking. Uma instância por contexto de sistema/Intercom. */
export default class TLocking {
    #Intercom;
    #Timeout;
    #Pending = new Map();
    #Disposed = false;
    #Intercom = null
    #Locking = null

    constructor(intercom, timeout = 30000) {
        if (!intercom || typeof intercom.Send !== "function")
            throw new TypeError("Informe uma instância de TIntercom.");

        if (!Number.isInteger(timeout) || timeout < 1 || timeout > 2147483647)
            throw new RangeError("Informe um timeout válido, em milissegundos.");

        this.#Intercom = intercom;
        this.#Timeout = timeout;
    }

    static Start(url) {
        this.#Intercom = new TIntercom(url);
        this.#Locking = new TLocking(this.#Intercom);
        this.#Intercom.OnMessage = message => {
            if (this.#Locking.Receive(message))
                return;

            // Tratar as demais mensagens.
        };

        this.#Intercom.OnClose = () => {
            this.#Locking.Disconnected();
        };

        await this.#Intercom.Connect();

        return {
            Intercom = this.#Intercom,
            Locking = this.#Locking
        }
    }

    DatabaseLock(databaseId, transactionId = null) {
        return this.#Request("DatabaseLock", {
            DatabaseId: databaseId,
            TransactionId: transactionId
        });
    }

    TableLock(databaseId, tableId, transactionId = null) {
        return this.#Request("TableLock", {
            DatabaseId: databaseId,
            TableId: tableId,
            TransactionId: transactionId
        });
    }

    RowLock(databaseId, tableId, recordId, transactionId = null) {
        return this.#Request("RowLock", {
            DatabaseId: databaseId,
            TableId: tableId,
            RecordId: recordId,
            TransactionId: transactionId
        });
    }

    Unlock(lockingId) {
        return this.#Request("Unlock", { LockingId: lockingId });
    }

    IsLocked(databaseId, tableId = null, recordId = null) {
        return this.#Request("IsLocked", {
            DatabaseId: databaseId,
            TableId: tableId,
            RecordId: recordId
        });
    }

    /**
     * Encaminhar aqui as mensagens recebidas pelo Intercom.
     * Retorna true se consumiu uma resposta própria; false nos demais casos.
     * Não substitui OnMessage nem interfere nos outros usos do Intercom.
     */
    Receive(message) {
        if (!message || message.Target !== "Locking")
            return false;

        const pending = this.#Pending.get(message.RequestId);

        if (!pending)
            return false;

        this.#Pending.delete(message.RequestId);
        clearTimeout(pending.Timer);

        if (message.Error != null) {
            const error = new Error(
                typeof message.Error === "string"
                    ? message.Error
                    : message.Error.Message ?? "Falha na operação de travamento."
            );
            error.Details = message.Error;
            pending.Reject(error);
        } else {
            pending.Resolve(message.Result);
        }

        return true;
    }

    /** Chamar no OnClose do Intercom para encerrar as esperas locais. */
    Disconnected(reason = "A conexão com a API foi encerrada.") {
        for (const pending of this.#Pending.values()) {
            clearTimeout(pending.Timer);
            pending.Reject(new Error(reason));
        }

        this.#Pending.clear();
    }

    /** Não fecha o Intercom, que pode ser usado por outros componentes. */
    Dispose() {
        this.#Disposed = true;
        this.Disconnected("A instância de TLocking foi encerrada.");
    }

    async #Request(method, parameters) {
        if (this.#Disposed)
            throw new Error("A instância de TLocking foi encerrada.");

        if (!this.#Intercom.IsOpen)
            throw new Error("O Intercom não está conectado.");

        const requestId = crypto.randomUUID();

        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                this.#Pending.delete(requestId);
                reject(new Error(`A API não respondeu a ${method} dentro do prazo.`));
            }, this.#Timeout);

            this.#Pending.set(requestId, {
                Resolve: resolve,
                Reject: reject,
                Timer: timer
            });

            try {
                this.#Intercom.Send({
                    Target: "Locking",
                    RequestId: requestId,
                    Method: method,
                    Parameters: parameters
                });
            } catch (error) {
                this.#Pending.delete(requestId);
                clearTimeout(timer);
                reject(error);
            }
        });
    }
}

/*
INTEGRAÇÃO — na classe do sistema, usando a TIntercom já criada:

    import TLocking from "./TLocking.class.mjs";

    this.Locking = new TLocking(this.Intercom);

    this.Intercom.OnMessage = message => {
        if (this.Locking.Receive(message))
            return;

        // Continuar aqui o tratamento das demais mensagens do sistema.
    };

    this.Intercom.OnClose = event => {
        this.Locking.Disconnected();
        // Continuar aqui o tratamento do encerramento da conexão.
    };

    await this.Intercom.Connect();

    // Quando o executor C# estiver integrado ao contrato abaixo:
    const result = await this.Locking.RowLock(1, 10, "123", 456);

    if (result.Acquired) {
        // Abrir a edição. Manter result.LockingId para liberar depois.
        await this.Locking.Unlock(result.LockingId);
    } else {
        // Informar que o recurso já está reservado.
    }

    // Ao descartar o contexto do sistema:
    this.Locking.Dispose();

CONTRATO A IMPLEMENTAR NO EXECUTOR C#:

    Pedido:
    {
        "Target": "Locking",
        "RequestId": "identificador da solicitação",
        "Method": "RowLock",
        "Parameters": {
            "DatabaseId": 1,
            "TableId": 10,
            "RecordId": "123",
            "TransactionId": 456
        }
    }

    Resposta positiva:
    {
        "Target": "Locking",
        "RequestId": "mesmo identificador do pedido",
        "Result": { "Acquired": true, "LockingId": 42 },
        "Error": null
    }

    Recurso indisponível:
    {
        "Target": "Locking",
        "RequestId": "mesmo identificador do pedido",
        "Result": { "Acquired": false, "LockingId": null },
        "Error": null
    }

    Erro de execução/validação:
    {
        "Target": "Locking",
        "RequestId": "mesmo identificador do pedido",
        "Result": null,
        "Error": { "Message": "Transação não está pendente." }
    }

    DatabaseLock, TableLock e RowLock retornam Acquired e LockingId.
    Unlock retorna { "Released": true/false }.
    IsLocked retorna { "IsLocked": true/false }.
    O significado de conflito e a autorização são decididos exclusivamente na API.
    LoginId e IntercomId vêm da associação validada no servidor.

    No Intercom.OnMessage do C#, o executor deverá reconhecer Target/Method,
    validar o contexto, executar a regra correspondente e responder por
    intercom.SendAsync(...) preservando Target e RequestId.

ESTADO DA INTEGRAÇÃO:
    A Locking.cs anterior possui armazenamento (Store/Remove/GetLockings),
    mas ainda NÃO possui esse dispatcher nem a aquisição com verificação de
    conflitos. Não basta encaminhar RowLock diretamente para Store.
    O exemplo de eco do Intercom também não produz respostas nesse contrato.
    Esta entrega cria o cliente e define o contrato para a próxima etapa do C#.

    Não há reenvio automático. Um timeout ou desconexão não prova que a API
    deixou de executar o pedido, nem libera uma reserva no servidor.
    O timeout de solicitação não implementa o Ping/Pong de presença.

VALIDAÇÃO:
    Testes simulados: respostas fora de ordem, separação entre instâncias,
    erros da API, timeout, desconexão, falha de envio e descarte.
    Ainda não houve teste integrado com a API C#.
*/
