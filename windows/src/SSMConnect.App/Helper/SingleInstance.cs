namespace SSMConnect.App.Helper;

/// <summary>
/// One shell per user session: the first launch owns a session-local mutex; a second launch
/// signals the first to come forward and exits without starting a helper.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    readonly Mutex mutex;
    readonly EventWaitHandle activation;
    readonly RegisteredWaitHandle registration;

    SingleInstance(Mutex mutex, EventWaitHandle activation)
    {
        this.mutex = mutex;
        this.activation = activation;
        registration = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) => Activated?.Invoke(), null, Timeout.Infinite, executeOnlyOnce: false);
    }

    /// <summary>Raised when a second launch asks this instance to come forward.</summary>
    public event Action? Activated;

    /// <summary>The instance when this is the first launch; otherwise signals the first and returns null.</summary>
    public static SingleInstance? TryAcquire(string name)
    {
        var activation = new EventWaitHandle(false, EventResetMode.AutoReset, $"Local\\{name}-activate");
        var mutex = new Mutex(true, $"Local\\{name}", out var createdNew);
        if (createdNew) return new SingleInstance(mutex, activation);
        activation.Set();
        activation.Dispose();
        mutex.Dispose();
        return null;
    }

    public void Dispose()
    {
        registration.Unregister(null);
        activation.Dispose();
        mutex.ReleaseMutex();
        mutex.Dispose();
    }
}
