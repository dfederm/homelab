var builder = WebApplication.CreateBuilder(args);

string? proxyConfigFile = Environment.GetEnvironmentVariable("REVERSE_PROXY_CONFIG_FILE");
if (proxyConfigFile is not null)
{
    builder.Configuration.AddJsonFile(proxyConfigFile, optional: false, reloadOnChange: true);
}

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"));

var app = builder.Build();
app.MapReverseProxy();

app.Run();