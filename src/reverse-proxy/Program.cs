using LettuceEncrypt;

var builder = WebApplication.CreateBuilder(args);

string? proxyConfigFile = Environment.GetEnvironmentVariable("REVERSE_PROXY_CONFIG_FILE");
if (proxyConfigFile is not null)
{
    builder.Configuration.AddJsonFile(proxyConfigFile, optional: false, reloadOnChange: true);
}

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"));

ILettuceEncryptServiceBuilder lettuceEncrypt = builder.Services.AddLettuceEncrypt();

string? certificateDirectory = Environment.GetEnvironmentVariable("REVERSE_PROXY_CERTIFICATE_DIRECTORY");
if (certificateDirectory is not null)
{
    lettuceEncrypt.PersistDataToDirectory(new DirectoryInfo(certificateDirectory), pfxPassword: null);
}

var app = builder.Build();
app.MapReverseProxy();

app.Run();