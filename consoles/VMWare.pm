# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package consoles::VMWare;

use Mojo::Base -base, -signatures;

use FindBin '$Bin';
use Mojo::JSON qw(encode_json);
use Mojo::UserAgent;
use Mojo::URL;
use Mojo::Util qw(xml_escape);

has protocol => 'https';
has host => undef;
has vm_id => 1;
has username => 'root';
has password => undef;
has dewebsockify_pid => undef;

sub _get_vmware_error ($dom) {
    my $faultstring_element = $dom->find('faultstring')->first;
    return $faultstring_element ? $faultstring_element->text : '';
}

sub _prepare_vmware_request ($ua, $api_url, $xml) {
    my $txn = $ua->build_tx(POST => $api_url);
    my $headers = $txn->req->headers;
    $txn->req->body($xml);
    $headers->header(SOAPAction => 'urn:vim25/7.0.2.0');
    $headers->content_type('text/xml');
    $headers->content_length(length $xml);
    return ($txn, $headers);
}

sub configure_from_url ($self, $url) {
    $url = Mojo::URL->new($url);
    $self->protocol($url->protocol)->host($url->host);
    $self->username($url->username)->password($url->password);
    $self->vm_id(substr $url->path, 1);
}

sub get_vmware_wss_url ($self) {

    # make XML for requests
    my $protocol = $self->protocol or die "No protocol specified\n";
    my $host = $self->host or die "No VMWare host specified\n";
    my $api_url = "$protocol://$host/sdk";
    my $username = xml_escape $self->username;
    my $password = xml_escape $self->password;
    my $vm_id = xml_escape $self->vm_id;
    my $auth_xml = qq{<Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Header><operationID>esxui-8fb8</operationID></Header><Body><Login xmlns="urn:vim25"><_this type="SessionManager">ha-sessionmgr</_this><userName>$username</userName><password>$password</password></Login></Body></Envelope>};
    my $request_wss_xml = qq{<Envelope xmlns="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Header><operationID>esxui-c51d</operationID></Header><Body><AcquireTicket xmlns="urn:vim25"><_this type="VirtualMachine">$vm_id</_this><ticketType>webmks</ticketType></AcquireTicket></Body></Envelope>};

    # request VMWare session
    my $ua = ($self->{_vmware_ua} //= Mojo::UserAgent->new);
    my ($auth_txn, $auth_headers) = _prepare_vmware_request($ua, $api_url, $auth_xml);
    $auth_headers->cookie('vmware_client=VMware');
    $ua->insecure(1);    # so far our setup doesn't have a proper certificate
    $ua->start($auth_txn);

    # check for auth error
    my $auth_error = _get_vmware_error($auth_txn->result->dom);
    die "VMWare auth request failed: $auth_error\n" if $auth_error;

    # request web socket URL
    my ($request_wss_txn) = _prepare_vmware_request($ua, $api_url, $request_wss_xml);
    $ua->start($request_wss_txn);

    # read web socket URL
    my $res = $request_wss_txn->result;
    my $wss_dom = $res->dom;
    my $url_error = _get_vmware_error($wss_dom);
    die "VMWare web socket URL request failed: $url_error\n" if $url_error;
    my $wss_url = $wss_dom->find('url')->first;
    die "VMWare did not return a web socket URL\n" unless $wss_url && $wss_url->text;
    my $cookie = $request_wss_txn->req->cookies->[0];
    die "VMWare did not return a session cookie\n" unless $cookie;
    return (Mojo::URL->new($wss_url->text), $cookie);
}

sub _cleanup_previous_dewebsockify_process ($self) {
    return undef unless my $pid = $self->dewebsockify_pid;
    kill SIGTERM => $pid;
    waitpid $pid, 0;
    $self->dewebsockify_pid(undef);
}

sub _start_dewebsockify_process ($self, $listen_port, $websockets_url, $session) {
    my $pid = fork;
    return $self->dewebsockify_pid($pid) if $pid;
    exec "$Bin/dewebsockify", '--listenport', $listen_port, '--websocketurl', $websockets_url, '--cookie', "vmware_client=VMware; $session";
}

sub launch_vnc_server ($self, $listen_port) {
    $self->_cleanup_previous_dewebsockify_process;
    $self->_start_dewebsockify_process($listen_port, $self->get_vmware_wss_url);
}

1;
