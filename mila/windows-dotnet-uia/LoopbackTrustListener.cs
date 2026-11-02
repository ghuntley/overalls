using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;

namespace Mila.Windows.Uia;

/// <summary>One TCP connection the client opened to the loopback trust listener.</summary>
internal sealed record LoopbackConnection(string Remote, string? ServerName);

/// <summary>
/// Accepts the client's HTTPS trust-document fetch for <c>localhost</c> on
/// port 443 and never answers it, so the fetch fails closed on its own
/// timeout and nothing is pinned. Each accepted connection is recorded with
/// the TLS ClientHello's server name, when the client sent one.
/// </summary>
internal sealed class LoopbackTrustListener : IDisposable
{
    private const int MaximumRecordBytes = 5 + 16 * 1024;
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _stop = new();
    private readonly Channel<LoopbackConnection> _connections = Channel.CreateUnbounded<LoopbackConnection>();
    private readonly List<TcpClient> _held = [];
    private int _accepted;

    private LoopbackTrustListener(TcpListener listener)
    {
        _listener = listener;
        _ = AcceptAsync();
    }

    /// <summary>Connections accepted so far.</summary>
    internal int Accepted => Volatile.Read(ref _accepted);

    internal static LoopbackTrustListener Start(int port)
    {
        TcpListener listener = new(IPAddress.IPv6Any, port);
        listener.Server.DualMode = true;
        try
        {
            listener.Start();
        }
        catch (SocketException error)
        {
            throw new UiaCheckFailed(
                $"the loopback trust listener could not bind [::]:{port} ({error.SocketErrorCode}); " +
                "another process holds the port, so the sign-in target cannot be observed");
        }
        return new LoopbackTrustListener(listener);
    }

    /// <summary>The next recorded connection, or null when none arrives in time.</summary>
    internal LoopbackConnection? Next(TimeSpan timeout)
    {
        using CancellationTokenSource wait = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
        wait.CancelAfter(timeout);
        try
        {
            return _connections.Reader.ReadAsync(wait.Token).AsTask().GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    private async Task AcceptAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener.AcceptTcpClientAsync(_stop.Token);
            }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or SocketException)
            {
                return;
            }
            lock (_held) _held.Add(client);
            Interlocked.Increment(ref _accepted);
            _ = RecordAsync(client);
        }
    }

    private async Task RecordAsync(TcpClient client)
    {
        string remote = client.Client.RemoteEndPoint?.ToString() ?? "<unknown>";
        byte[] buffer = new byte[MaximumRecordBytes];
        int filled = 0;
        using CancellationTokenSource read = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
        read.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            NetworkStream stream = client.GetStream();
            while (filled < buffer.Length)
            {
                int count = await stream.ReadAsync(buffer.AsMemory(filled), read.Token);
                if (count == 0) break;
                filled += count;
                if (filled >= 5 && filled >= 5 + ((buffer[3] << 8) | buffer[4])) break;
            }
        }
        catch (Exception error) when (error is OperationCanceledException or IOException or ObjectDisposedException)
        {
        }
        // The connection stays open and unanswered until the listener is disposed.
        _connections.Writer.TryWrite(new LoopbackConnection(remote, ServerName(buffer.AsSpan(0, filled))));
    }

    /// <summary>The SNI host name of a TLS ClientHello record, or null when absent or malformed.</summary>
    internal static string? ServerName(ReadOnlySpan<byte> record)
    {
        if (record.Length < 5 || record[0] != 22) return null;
        int recordLength = (record[3] << 8) | record[4];
        ReadOnlySpan<byte> body = record.Slice(5, Math.Min(recordLength, record.Length - 5));
        if (body.Length < 4 || body[0] != 1) return null;
        int position = 4 + 2 + 32;
        if (body.Length < position + 1) return null;
        position += 1 + body[position];
        if (body.Length < position + 2) return null;
        position += 2 + ((body[position] << 8) | body[position + 1]);
        if (body.Length < position + 1) return null;
        position += 1 + body[position];
        if (body.Length < position + 2) return null;
        int end = Math.Min(body.Length, position + 2 + ((body[position] << 8) | body[position + 1]));
        position += 2;
        while (position + 4 <= end)
        {
            int type = (body[position] << 8) | body[position + 1];
            int length = (body[position + 2] << 8) | body[position + 3];
            position += 4;
            if (position + length > end) return null;
            if (type == 0)
            {
                ReadOnlySpan<byte> extension = body.Slice(position, length);
                if (extension.Length < 5 || extension[2] != 0) return null;
                int nameLength = (extension[3] << 8) | extension[4];
                return 5 + nameLength > extension.Length ? null : Encoding.ASCII.GetString(extension.Slice(5, nameLength));
            }
            position += length;
        }
        return null;
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
        lock (_held)
        {
            foreach (TcpClient client in _held) client.Dispose();
            _held.Clear();
        }
        // _stop stays undisposed: accept and record tasks may still observe it.
    }
}
