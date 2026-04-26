use Test2::V0;
use Test2::Require::Module 'Compress::Zstd' => '0.20';

use IPC::Manager::Serializer::JSON::Zstd;

subtest 'viable' => sub {
    ok(IPC::Manager::Serializer::JSON::Zstd->viable, "viable when Compress::Zstd is loadable");
};

subtest 'isa JSON' => sub {
    isa_ok('IPC::Manager::Serializer::JSON::Zstd', ['IPC::Manager::Serializer::JSON']);
    isa_ok('IPC::Manager::Serializer::JSON::Zstd', ['IPC::Manager::Serializer']);
};

subtest 'round-trip hash' => sub {
    my $data  = {foo => 'bar', num => 42};
    my $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize($data);
    ok(defined $bytes, "serialize returns bytes");
    my $back = IPC::Manager::Serializer::JSON::Zstd->deserialize($bytes);
    is($back, $data, "round-trip preserves data");
};

subtest 'round-trip array' => sub {
    my $data  = [1, 'two', {three => 3}];
    my $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize($data);
    my $back  = IPC::Manager::Serializer::JSON::Zstd->deserialize($bytes);
    is($back, $data, "round-trip array");
};

subtest 'round-trip scalar' => sub {
    my $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize("hello");
    my $back  = IPC::Manager::Serializer::JSON::Zstd->deserialize($bytes);
    is($back, "hello", "round-trip scalar");
};

subtest 'convert_blessed' => sub {
    require IPC::Manager::Message;
    my $msg   = IPC::Manager::Message->new(from => 'a', to => 'b', content => 'x');
    my $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize($msg);
    my $back  = IPC::Manager::Serializer::JSON::Zstd->deserialize($bytes);
    is($back->{from}, 'a', "blessed object serialized via TO_JSON");
};

subtest 'compresses repetitive payload' => sub {
    my $data  = {blob => 'A' x 4096};
    my $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize($data);
    my $json  = IPC::Manager::Serializer::JSON->serialize($data);
    ok(length($bytes) < length($json), "zstd output is smaller than raw JSON for repetitive input")
        or diag("zstd=", length($bytes), " json=", length($json));
    my $back = IPC::Manager::Serializer::JSON::Zstd->deserialize($bytes);
    is($back, $data, "round-trip large payload");
};

subtest 'rejects truncated payload' => sub {
    my $bytes = IPC::Manager::Serializer::JSON::Zstd->serialize({a => 1});
    my $bad   = substr($bytes, 0, length($bytes) - 4);
    like(
        dies { IPC::Manager::Serializer::JSON::Zstd->deserialize($bad) },
        qr/Failed to decompress|decompress|Compress::Zstd/i,
        "truncated payload throws",
    );
};

done_testing;
