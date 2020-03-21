/*
 * Copyright (C) 2020 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This library is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

module asgen.bindings.soup.c;

private import glib.c.types;
private import gobject.c.types;
private import gio.c.types;

extern(C):
nothrow:
@nogc:

struct SoupSession
{
    GObject parent;
}

struct SoupProxyResolverDefault
{
    GObject parent;
}

struct SoupProxyResolverDefaultClass
{
    GObjectClass parentClass;
}

public enum SoupMessageHeadersType
{
    REQUEST = 0,
    RESPONSE = 1,
    MULTIPART = 2,
}
alias MessageHeadersType = SoupMessageHeadersType;

struct SoupMessageHeaders;

struct SoupMessageHeadersIter
{
    void*[3] dummy;
}

struct SoupMessage
{
    GObject parent;
    const(char)* method;
    uint statusCode;
    char* reasonPhrase;
    SoupMessageBody* requestBody;
    SoupMessageHeaders* requestHeaders;
    SoupMessageBody* responseBody;
    SoupMessageHeaders* responseHeaders;
}

struct SoupMessageBody
{
    const(char)* data;
    long length;
}

struct SoupURI
{
    const(char)* scheme;
    char* user;
    char* password;
    char* host;
    uint port;
    char* path;
    char* query;
    char* fragment;
}

struct SoupSocket
{
    GObject parent;
}

struct SoupSocketClass
{
    GObjectClass parentClass;
    extern(C) void function(SoupSocket* sock) readable;
    extern(C) void function(SoupSocket* sock) writable;
    extern(C) void function(SoupSocket* sock) disconnected;
    extern(C) void function(SoupSocket* listener, SoupSocket* newSock) newConnection;
    extern(C) void function() LibsoupReserved1;
    extern(C) void function() LibsoupReserved2;
    extern(C) void function() LibsoupReserved3;
    extern(C) void function() LibsoupReserved4;
}

struct SoupSessionFeature;

struct SoupSessionFeatureInterface
{
    GTypeInterface parent;
    extern(C) void function(SoupSessionFeature* feature, SoupSession* session) attach;
    extern(C) void function(SoupSessionFeature* feature, SoupSession* session) detach;
    extern(C) void function(SoupSessionFeature* feature, SoupSession* session, SoupMessage* msg) requestQueued;
    extern(C) void function(SoupSessionFeature* feature, SoupSession* session, SoupMessage* msg, SoupSocket* socket) requestStarted;
    extern(C) void function(SoupSessionFeature* feature, SoupSession* session, SoupMessage* msg) requestUnqueued;
    extern(C) int function(SoupSessionFeature* feature, GType type) addFeature;
    extern(C) int function(SoupSessionFeature* feature, GType type) removeFeature;
    extern(C) int function(SoupSessionFeature* feature, GType type) hasFeature;
}

struct SoupAddress
{
    GObject parent;
}

public enum SoupMessageFlags
{
    NO_REDIRECT = 2,
    CAN_REBUILD = 4,
    OVERWRITE_CHUNKS = 8,
    CONTENT_DECODED = 16,
    CERTIFICATE_TRUSTED = 32,
    NEW_CONNECTION = 64,
    IDEMPOTENT = 128,
    IGNORE_CONNECTION_LIMITS = 256,
    DO_NOT_USE_AUTH_CACHE = 512,
}
alias MessageFlags = SoupMessageFlags;

public enum SoupHTTPVersion
{
    HTTP_1_0 = 0,
    HTTP_1_1 = 1,
}
alias HTTPVersion = SoupHTTPVersion;

public enum SoupMessagePriority
{
    VERY_LOW = 0,
    LOW = 1,
    NORMAL = 2,
    HIGH = 3,
    VERY_HIGH = 4,
}
alias MessagePriority = SoupMessagePriority;

struct SoupBuffer
{
    void* data;
    size_t length;
}

public enum SoupMemoryUse
{
    STATIC = 0,
    TAKE = 1,
    COPY = 2,
    TEMPORARY = 3,
}
alias MemoryUse = SoupMemoryUse;

// constants

enum ADDRESS_ANY_PORT = 0;
alias SOUP_ADDRESS_ANY_PORT = ADDRESS_ANY_PORT;

enum ADDRESS_FAMILY = "family";
alias SOUP_ADDRESS_FAMILY = ADDRESS_FAMILY;

enum ADDRESS_NAME = "name";
alias SOUP_ADDRESS_NAME = ADDRESS_NAME;

enum ADDRESS_PHYSICAL = "physical";
alias SOUP_ADDRESS_PHYSICAL = ADDRESS_PHYSICAL;

enum ADDRESS_PORT = "port";
alias SOUP_ADDRESS_PORT = ADDRESS_PORT;

enum ADDRESS_PROTOCOL = "protocol";
alias SOUP_ADDRESS_PROTOCOL = ADDRESS_PROTOCOL;

enum ADDRESS_SOCKADDR = "sockaddr";
alias SOUP_ADDRESS_SOCKADDR = ADDRESS_SOCKADDR;

enum AUTH_DOMAIN_ADD_PATH = "add-path";
alias SOUP_AUTH_DOMAIN_ADD_PATH = AUTH_DOMAIN_ADD_PATH;

enum AUTH_DOMAIN_BASIC_AUTH_CALLBACK = "auth-callback";
alias SOUP_AUTH_DOMAIN_BASIC_AUTH_CALLBACK = AUTH_DOMAIN_BASIC_AUTH_CALLBACK;

enum AUTH_DOMAIN_BASIC_AUTH_DATA = "auth-data";
alias SOUP_AUTH_DOMAIN_BASIC_AUTH_DATA = AUTH_DOMAIN_BASIC_AUTH_DATA;

enum AUTH_DOMAIN_DIGEST_AUTH_CALLBACK = "auth-callback";
alias SOUP_AUTH_DOMAIN_DIGEST_AUTH_CALLBACK = AUTH_DOMAIN_DIGEST_AUTH_CALLBACK;

enum AUTH_DOMAIN_DIGEST_AUTH_DATA = "auth-data";
alias SOUP_AUTH_DOMAIN_DIGEST_AUTH_DATA = AUTH_DOMAIN_DIGEST_AUTH_DATA;

enum AUTH_DOMAIN_FILTER = "filter";
alias SOUP_AUTH_DOMAIN_FILTER = AUTH_DOMAIN_FILTER;

enum AUTH_DOMAIN_FILTER_DATA = "filter-data";
alias SOUP_AUTH_DOMAIN_FILTER_DATA = AUTH_DOMAIN_FILTER_DATA;

enum AUTH_DOMAIN_GENERIC_AUTH_CALLBACK = "generic-auth-callback";
alias SOUP_AUTH_DOMAIN_GENERIC_AUTH_CALLBACK = AUTH_DOMAIN_GENERIC_AUTH_CALLBACK;

enum AUTH_DOMAIN_GENERIC_AUTH_DATA = "generic-auth-data";
alias SOUP_AUTH_DOMAIN_GENERIC_AUTH_DATA = AUTH_DOMAIN_GENERIC_AUTH_DATA;

enum AUTH_DOMAIN_PROXY = "proxy";
alias SOUP_AUTH_DOMAIN_PROXY = AUTH_DOMAIN_PROXY;

enum AUTH_DOMAIN_REALM = "realm";
alias SOUP_AUTH_DOMAIN_REALM = AUTH_DOMAIN_REALM;

enum AUTH_DOMAIN_REMOVE_PATH = "remove-path";
alias SOUP_AUTH_DOMAIN_REMOVE_PATH = AUTH_DOMAIN_REMOVE_PATH;

enum AUTH_HOST = "host";
alias SOUP_AUTH_HOST = AUTH_HOST;

enum AUTH_IS_AUTHENTICATED = "is-authenticated";
alias SOUP_AUTH_IS_AUTHENTICATED = AUTH_IS_AUTHENTICATED;

enum AUTH_IS_FOR_PROXY = "is-for-proxy";
alias SOUP_AUTH_IS_FOR_PROXY = AUTH_IS_FOR_PROXY;

enum AUTH_REALM = "realm";
alias SOUP_AUTH_REALM = AUTH_REALM;

enum AUTH_SCHEME_NAME = "scheme-name";
alias SOUP_AUTH_SCHEME_NAME = AUTH_SCHEME_NAME;

enum CHAR_HTTP_CTL = 16;
alias SOUP_CHAR_HTTP_CTL = CHAR_HTTP_CTL;

enum CHAR_HTTP_SEPARATOR = 8;
alias SOUP_CHAR_HTTP_SEPARATOR = CHAR_HTTP_SEPARATOR;

enum CHAR_URI_GEN_DELIMS = 2;
alias SOUP_CHAR_URI_GEN_DELIMS = CHAR_URI_GEN_DELIMS;

enum CHAR_URI_PERCENT_ENCODED = 1;
alias SOUP_CHAR_URI_PERCENT_ENCODED = CHAR_URI_PERCENT_ENCODED;

enum CHAR_URI_SUB_DELIMS = 4;
alias SOUP_CHAR_URI_SUB_DELIMS = CHAR_URI_SUB_DELIMS;

enum COOKIE_JAR_ACCEPT_POLICY = "accept-policy";
alias SOUP_COOKIE_JAR_ACCEPT_POLICY = COOKIE_JAR_ACCEPT_POLICY;

enum COOKIE_JAR_DB_FILENAME = "filename";
alias SOUP_COOKIE_JAR_DB_FILENAME = COOKIE_JAR_DB_FILENAME;

enum COOKIE_JAR_READ_ONLY = "read-only";
alias SOUP_COOKIE_JAR_READ_ONLY = COOKIE_JAR_READ_ONLY;

enum COOKIE_JAR_TEXT_FILENAME = "filename";
alias SOUP_COOKIE_JAR_TEXT_FILENAME = COOKIE_JAR_TEXT_FILENAME;

enum COOKIE_MAX_AGE_ONE_DAY = 0;
alias SOUP_COOKIE_MAX_AGE_ONE_DAY = COOKIE_MAX_AGE_ONE_DAY;

enum COOKIE_MAX_AGE_ONE_HOUR = 3600;
alias SOUP_COOKIE_MAX_AGE_ONE_HOUR = COOKIE_MAX_AGE_ONE_HOUR;

enum COOKIE_MAX_AGE_ONE_WEEK = 0;
alias SOUP_COOKIE_MAX_AGE_ONE_WEEK = COOKIE_MAX_AGE_ONE_WEEK;

enum COOKIE_MAX_AGE_ONE_YEAR = 0;
alias SOUP_COOKIE_MAX_AGE_ONE_YEAR = COOKIE_MAX_AGE_ONE_YEAR;

enum FORM_MIME_TYPE_MULTIPART = "multipart/form-data";
alias SOUP_FORM_MIME_TYPE_MULTIPART = FORM_MIME_TYPE_MULTIPART;

enum FORM_MIME_TYPE_URLENCODED = "application/x-www-form-urlencoded";
alias SOUP_FORM_MIME_TYPE_URLENCODED = FORM_MIME_TYPE_URLENCODED;

enum HSTS_ENFORCER_DB_FILENAME = "filename";
alias SOUP_HSTS_ENFORCER_DB_FILENAME = HSTS_ENFORCER_DB_FILENAME;

enum HSTS_POLICY_MAX_AGE_PAST = 0;
alias SOUP_HSTS_POLICY_MAX_AGE_PAST = HSTS_POLICY_MAX_AGE_PAST;

enum LOGGER_LEVEL = "level";
alias SOUP_LOGGER_LEVEL = LOGGER_LEVEL;

enum LOGGER_MAX_BODY_SIZE = "max-body-size";
alias SOUP_LOGGER_MAX_BODY_SIZE = LOGGER_MAX_BODY_SIZE;

enum MAJOR_VERSION = 2;
alias SOUP_MAJOR_VERSION = MAJOR_VERSION;

enum MESSAGE_FIRST_PARTY = "first-party";
alias SOUP_MESSAGE_FIRST_PARTY = MESSAGE_FIRST_PARTY;

enum MESSAGE_FLAGS = "flags";
alias SOUP_MESSAGE_FLAGS = MESSAGE_FLAGS;

enum MESSAGE_HTTP_VERSION = "http-version";
alias SOUP_MESSAGE_HTTP_VERSION = MESSAGE_HTTP_VERSION;

enum MESSAGE_IS_TOP_LEVEL_NAVIGATION = "is-top-level-navigation";
alias SOUP_MESSAGE_IS_TOP_LEVEL_NAVIGATION = MESSAGE_IS_TOP_LEVEL_NAVIGATION;

enum MESSAGE_METHOD = "method";
alias SOUP_MESSAGE_METHOD = MESSAGE_METHOD;

enum MESSAGE_PRIORITY = "priority";
alias SOUP_MESSAGE_PRIORITY = MESSAGE_PRIORITY;

enum MESSAGE_REASON_PHRASE = "reason-phrase";
alias SOUP_MESSAGE_REASON_PHRASE = MESSAGE_REASON_PHRASE;

enum MESSAGE_REQUEST_BODY = "request-body";
alias SOUP_MESSAGE_REQUEST_BODY = MESSAGE_REQUEST_BODY;

enum MESSAGE_REQUEST_BODY_DATA = "request-body-data";
alias SOUP_MESSAGE_REQUEST_BODY_DATA = MESSAGE_REQUEST_BODY_DATA;

enum MESSAGE_REQUEST_HEADERS = "request-headers";
alias SOUP_MESSAGE_REQUEST_HEADERS = MESSAGE_REQUEST_HEADERS;

enum MESSAGE_RESPONSE_BODY = "response-body";
alias SOUP_MESSAGE_RESPONSE_BODY = MESSAGE_RESPONSE_BODY;

enum MESSAGE_RESPONSE_BODY_DATA = "response-body-data";
alias SOUP_MESSAGE_RESPONSE_BODY_DATA = MESSAGE_RESPONSE_BODY_DATA;

enum MESSAGE_RESPONSE_HEADERS = "response-headers";
alias SOUP_MESSAGE_RESPONSE_HEADERS = MESSAGE_RESPONSE_HEADERS;

enum MESSAGE_SERVER_SIDE = "server-side";
alias SOUP_MESSAGE_SERVER_SIDE = MESSAGE_SERVER_SIDE;

enum MESSAGE_SITE_FOR_COOKIES = "site-for-cookies";
alias SOUP_MESSAGE_SITE_FOR_COOKIES = MESSAGE_SITE_FOR_COOKIES;

enum MESSAGE_STATUS_CODE = "status-code";
alias SOUP_MESSAGE_STATUS_CODE = MESSAGE_STATUS_CODE;

enum MESSAGE_TLS_CERTIFICATE = "tls-certificate";
alias SOUP_MESSAGE_TLS_CERTIFICATE = MESSAGE_TLS_CERTIFICATE;

enum MESSAGE_TLS_ERRORS = "tls-errors";
alias SOUP_MESSAGE_TLS_ERRORS = MESSAGE_TLS_ERRORS;

enum MESSAGE_URI = "uri";
alias SOUP_MESSAGE_URI = MESSAGE_URI;

enum MICRO_VERSION = 0;
alias SOUP_MICRO_VERSION = MICRO_VERSION;

enum MINOR_VERSION = 70;
alias SOUP_MINOR_VERSION = MINOR_VERSION;

enum REQUEST_SESSION = "session";
alias SOUP_REQUEST_SESSION = REQUEST_SESSION;

enum REQUEST_URI = "uri";
alias SOUP_REQUEST_URI = REQUEST_URI;

enum SERVER_ADD_WEBSOCKET_EXTENSION = "add-websocket-extension";
alias SOUP_SERVER_ADD_WEBSOCKET_EXTENSION = SERVER_ADD_WEBSOCKET_EXTENSION;

enum SERVER_ASYNC_CONTEXT = "async-context";
alias SOUP_SERVER_ASYNC_CONTEXT = SERVER_ASYNC_CONTEXT;

enum SERVER_HTTPS_ALIASES = "https-aliases";
alias SOUP_SERVER_HTTPS_ALIASES = SERVER_HTTPS_ALIASES;

enum SERVER_HTTP_ALIASES = "http-aliases";
alias SOUP_SERVER_HTTP_ALIASES = SERVER_HTTP_ALIASES;

enum SERVER_INTERFACE = "interface";
alias SOUP_SERVER_INTERFACE = SERVER_INTERFACE;

enum SERVER_PORT = "port";
alias SOUP_SERVER_PORT = SERVER_PORT;

enum SERVER_RAW_PATHS = "raw-paths";
alias SOUP_SERVER_RAW_PATHS = SERVER_RAW_PATHS;

enum SERVER_REMOVE_WEBSOCKET_EXTENSION = "remove-websocket-extension";
alias SOUP_SERVER_REMOVE_WEBSOCKET_EXTENSION = SERVER_REMOVE_WEBSOCKET_EXTENSION;

enum SERVER_SERVER_HEADER = "server-header";
alias SOUP_SERVER_SERVER_HEADER = SERVER_SERVER_HEADER;

enum SERVER_SSL_CERT_FILE = "ssl-cert-file";
alias SOUP_SERVER_SSL_CERT_FILE = SERVER_SSL_CERT_FILE;

enum SERVER_SSL_KEY_FILE = "ssl-key-file";
alias SOUP_SERVER_SSL_KEY_FILE = SERVER_SSL_KEY_FILE;

enum SERVER_TLS_CERTIFICATE = "tls-certificate";
alias SOUP_SERVER_TLS_CERTIFICATE = SERVER_TLS_CERTIFICATE;

enum SESSION_ACCEPT_LANGUAGE = "accept-language";
alias SOUP_SESSION_ACCEPT_LANGUAGE = SESSION_ACCEPT_LANGUAGE;

enum SESSION_ACCEPT_LANGUAGE_AUTO = "accept-language-auto";
alias SOUP_SESSION_ACCEPT_LANGUAGE_AUTO = SESSION_ACCEPT_LANGUAGE_AUTO;

enum SESSION_ADD_FEATURE = "add-feature";
alias SOUP_SESSION_ADD_FEATURE = SESSION_ADD_FEATURE;

enum SESSION_ADD_FEATURE_BY_TYPE = "add-feature-by-type";
alias SOUP_SESSION_ADD_FEATURE_BY_TYPE = SESSION_ADD_FEATURE_BY_TYPE;

enum SESSION_ASYNC_CONTEXT = "async-context";
alias SOUP_SESSION_ASYNC_CONTEXT = SESSION_ASYNC_CONTEXT;

enum SESSION_HTTPS_ALIASES = "https-aliases";
alias SOUP_SESSION_HTTPS_ALIASES = SESSION_HTTPS_ALIASES;

enum SESSION_HTTP_ALIASES = "http-aliases";
alias SOUP_SESSION_HTTP_ALIASES = SESSION_HTTP_ALIASES;

enum SESSION_IDLE_TIMEOUT = "idle-timeout";
alias SOUP_SESSION_IDLE_TIMEOUT = SESSION_IDLE_TIMEOUT;

enum SESSION_LOCAL_ADDRESS = "local-address";
alias SOUP_SESSION_LOCAL_ADDRESS = SESSION_LOCAL_ADDRESS;

enum SESSION_MAX_CONNS = "max-conns";
alias SOUP_SESSION_MAX_CONNS = SESSION_MAX_CONNS;

enum SESSION_MAX_CONNS_PER_HOST = "max-conns-per-host";
alias SOUP_SESSION_MAX_CONNS_PER_HOST = SESSION_MAX_CONNS_PER_HOST;

enum SESSION_PROXY_RESOLVER = "proxy-resolver";
alias SOUP_SESSION_PROXY_RESOLVER = SESSION_PROXY_RESOLVER;

enum SESSION_PROXY_URI = "proxy-uri";
alias SOUP_SESSION_PROXY_URI = SESSION_PROXY_URI;

enum SESSION_REMOVE_FEATURE_BY_TYPE = "remove-feature-by-type";
alias SOUP_SESSION_REMOVE_FEATURE_BY_TYPE = SESSION_REMOVE_FEATURE_BY_TYPE;

enum SESSION_SSL_CA_FILE = "ssl-ca-file";
alias SOUP_SESSION_SSL_CA_FILE = SESSION_SSL_CA_FILE;

enum SESSION_SSL_STRICT = "ssl-strict";
alias SOUP_SESSION_SSL_STRICT = SESSION_SSL_STRICT;

enum SESSION_SSL_USE_SYSTEM_CA_FILE = "ssl-use-system-ca-file";
alias SOUP_SESSION_SSL_USE_SYSTEM_CA_FILE = SESSION_SSL_USE_SYSTEM_CA_FILE;

enum SESSION_TIMEOUT = "timeout";
alias SOUP_SESSION_TIMEOUT = SESSION_TIMEOUT;

enum SESSION_TLS_DATABASE = "tls-database";
alias SOUP_SESSION_TLS_DATABASE = SESSION_TLS_DATABASE;

enum SESSION_TLS_INTERACTION = "tls-interaction";
alias SOUP_SESSION_TLS_INTERACTION = SESSION_TLS_INTERACTION;

enum SESSION_USER_AGENT = "user-agent";
alias SOUP_SESSION_USER_AGENT = SESSION_USER_AGENT;

enum SESSION_USE_NTLM = "use-ntlm";
alias SOUP_SESSION_USE_NTLM = SESSION_USE_NTLM;

enum SESSION_USE_THREAD_CONTEXT = "use-thread-context";
alias SOUP_SESSION_USE_THREAD_CONTEXT = SESSION_USE_THREAD_CONTEXT;

enum SOCKET_ASYNC_CONTEXT = "async-context";
alias SOUP_SOCKET_ASYNC_CONTEXT = SOCKET_ASYNC_CONTEXT;

enum SOCKET_FLAG_NONBLOCKING = "non-blocking";
alias SOUP_SOCKET_FLAG_NONBLOCKING = SOCKET_FLAG_NONBLOCKING;

enum SOCKET_IS_SERVER = "is-server";
alias SOUP_SOCKET_IS_SERVER = SOCKET_IS_SERVER;

enum SOCKET_LOCAL_ADDRESS = "local-address";
alias SOUP_SOCKET_LOCAL_ADDRESS = SOCKET_LOCAL_ADDRESS;

enum SOCKET_REMOTE_ADDRESS = "remote-address";
alias SOUP_SOCKET_REMOTE_ADDRESS = SOCKET_REMOTE_ADDRESS;

enum SOCKET_SSL_CREDENTIALS = "ssl-creds";
alias SOUP_SOCKET_SSL_CREDENTIALS = SOCKET_SSL_CREDENTIALS;

enum SOCKET_SSL_FALLBACK = "ssl-fallback";
alias SOUP_SOCKET_SSL_FALLBACK = SOCKET_SSL_FALLBACK;

enum SOCKET_SSL_STRICT = "ssl-strict";
alias SOUP_SOCKET_SSL_STRICT = SOCKET_SSL_STRICT;

enum SOCKET_TIMEOUT = "timeout";
alias SOUP_SOCKET_TIMEOUT = SOCKET_TIMEOUT;

enum SOCKET_TLS_CERTIFICATE = "tls-certificate";
alias SOUP_SOCKET_TLS_CERTIFICATE = SOCKET_TLS_CERTIFICATE;

enum SOCKET_TLS_ERRORS = "tls-errors";
alias SOUP_SOCKET_TLS_ERRORS = SOCKET_TLS_ERRORS;

enum SOCKET_TRUSTED_CERTIFICATE = "trusted-certificate";
alias SOUP_SOCKET_TRUSTED_CERTIFICATE = SOCKET_TRUSTED_CERTIFICATE;

enum SOCKET_USE_THREAD_CONTEXT = "use-thread-context";
alias SOUP_SOCKET_USE_THREAD_CONTEXT = SOCKET_USE_THREAD_CONTEXT;

enum VERSION_MIN_REQUIRED = 2;
alias SOUP_VERSION_MIN_REQUIRED = VERSION_MIN_REQUIRED;

// soup.Session

GType soup_session_get_type ();
SoupSession* soup_session_new ();
SoupSession* soup_session_new_with_options (const(char)* optname1, ... );
void soup_session_abort (SoupSession* session);
void soup_session_add_feature (SoupSession* session, SoupSessionFeature* feature);
void soup_session_add_feature_by_type (SoupSession* session, GType featureType);
void soup_session_cancel_message (SoupSession* session, SoupMessage* msg, uint statusCode);
GMainContext* soup_session_get_async_context (SoupSession* session);
SoupSessionFeature* soup_session_get_feature (SoupSession* session, GType featureType);
SoupSessionFeature* soup_session_get_feature_for_message (SoupSession* session, GType featureType, SoupMessage* msg);
GSList* soup_session_get_features (SoupSession* session, GType featureType);
int soup_session_has_feature (SoupSession* session, GType featureType);
void soup_session_pause_message (SoupSession* session, SoupMessage* msg);
void soup_session_prepare_for_uri (SoupSession* session, SoupURI* uri);
int soup_session_redirect_message (SoupSession* session, SoupMessage* msg);
void soup_session_remove_feature (SoupSession* session, SoupSessionFeature* feature);
void soup_session_remove_feature_by_type (SoupSession* session, GType featureType);
void soup_session_requeue_message (SoupSession* session, SoupMessage* msg);
GInputStream* soup_session_send (SoupSession* session, SoupMessage* msg, GCancellable* cancellable, GError** err);
void soup_session_send_async (SoupSession* session, SoupMessage* msg, GCancellable* cancellable, GAsyncReadyCallback callback, void* userData);
GInputStream* soup_session_send_finish (SoupSession* session, GAsyncResult* result, GError** err);
uint soup_session_send_message (SoupSession* session, SoupMessage* msg);
GIOStream* soup_session_steal_connection (SoupSession* session, SoupMessage* msg);
void soup_session_unpause_message (SoupSession* session, SoupMessage* msg);
void soup_session_websocket_connect_async (SoupSession* session, SoupMessage* msg, const(char)* origin, char** protocols, GCancellable* cancellable, GAsyncReadyCallback callback, void* userData);
int soup_session_would_redirect (SoupSession* session, SoupMessage* msg);

// soup.ProxyResolverDefault

GType soup_proxy_resolver_default_get_type ();

// soup.Message

GType soup_message_get_type();
SoupMessage* soup_message_new(const(char)* method, const(char)* uriString);
SoupMessage* soup_message_new_from_uri(const(char)* method, SoupURI* uri);
uint soup_message_add_header_handler(SoupMessage* msg, const(char)* signal, const(char)* header, GCallback callback, void* userData);
uint soup_message_add_status_code_handler(SoupMessage* msg, const(char)* signal, uint statusCode, GCallback callback, void* userData);
void soup_message_content_sniffed(SoupMessage* msg, const(char)* contentType, GHashTable* params);
void soup_message_disable_feature(SoupMessage* msg, GType featureType);
void soup_message_finished(SoupMessage* msg);
SoupAddress* soup_message_get_address(SoupMessage* msg);
SoupURI* soup_message_get_first_party(SoupMessage* msg);
SoupMessageFlags soup_message_get_flags(SoupMessage* msg);
SoupHTTPVersion soup_message_get_http_version(SoupMessage* msg);
int soup_message_get_https_status(SoupMessage* msg, GTlsCertificate** certificate, GTlsCertificateFlags* errors);
int soup_message_get_is_top_level_navigation(SoupMessage* msg);
SoupMessagePriority soup_message_get_priority(SoupMessage* msg);
SoupURI* soup_message_get_site_for_cookies(SoupMessage* msg);
SoupURI* soup_message_get_uri(SoupMessage* msg);
void soup_message_got_body(SoupMessage* msg);
void soup_message_got_chunk(SoupMessage* msg, SoupBuffer* chunk);
void soup_message_got_headers(SoupMessage* msg);
void soup_message_got_informational(SoupMessage* msg);
int soup_message_is_keepalive(SoupMessage* msg);
void soup_message_restarted(SoupMessage* msg);
void soup_message_set_first_party(SoupMessage* msg, SoupURI* firstParty);
void soup_message_set_flags(SoupMessage* msg, SoupMessageFlags flags);
void soup_message_set_http_version(SoupMessage* msg, SoupHTTPVersion version_);
void soup_message_set_is_top_level_navigation(SoupMessage* msg, int isTopLevelNavigation);
void soup_message_set_priority(SoupMessage* msg, SoupMessagePriority priority);
void soup_message_set_redirect(SoupMessage* msg, uint statusCode, const(char)* redirectUri);
void soup_message_set_request(SoupMessage* msg, const(char)* contentType, SoupMemoryUse reqUse, char* reqBody, size_t reqLength);
void soup_message_set_response(SoupMessage* msg, const(char)* contentType, SoupMemoryUse respUse, char* respBody, size_t respLength);
void soup_message_set_site_for_cookies(SoupMessage* msg, SoupURI* siteForCookies);
void soup_message_set_status(SoupMessage* msg, uint statusCode);
void soup_message_set_status_full(SoupMessage* msg, uint statusCode, const(char)* reasonPhrase);
void soup_message_set_uri(SoupMessage* msg, SoupURI* uri);
void soup_message_starting(SoupMessage* msg);
void soup_message_wrote_body(SoupMessage* msg);
void soup_message_wrote_body_data(SoupMessage* msg, SoupBuffer* chunk);
void soup_message_wrote_chunk(SoupMessage* msg);
void soup_message_wrote_headers(SoupMessage* msg);
void soup_message_wrote_informational(SoupMessage* msg);

// soup.MessageBody

GType soup_message_body_get_type();
SoupMessageBody* soup_message_body_new();
void soup_message_body_append(SoupMessageBody* body_, SoupMemoryUse use, void* data, size_t length);
void soup_message_body_append_buffer(SoupMessageBody* body_, SoupBuffer* buffer);
void soup_message_body_append_take(SoupMessageBody* body_, char* data, size_t length);
void soup_message_body_complete(SoupMessageBody* body_);
SoupBuffer* soup_message_body_flatten(SoupMessageBody* body_);
void soup_message_body_free(SoupMessageBody* body_);
int soup_message_body_get_accumulate(SoupMessageBody* body_);
SoupBuffer* soup_message_body_get_chunk(SoupMessageBody* body_, long offset);
void soup_message_body_got_chunk(SoupMessageBody* body_, SoupBuffer* chunk);
void soup_message_body_set_accumulate(SoupMessageBody* body_, int accumulate);
void soup_message_body_truncate(SoupMessageBody* body_);
void soup_message_body_wrote_chunk(SoupMessageBody* body_, SoupBuffer* chunk);

// soup.URI

GType soup_uri_get_type();
SoupURI* soup_uri_new(const(char)* uriString);
SoupURI* soup_uri_new_with_base(SoupURI* base, const(char)* uriString);
SoupURI* soup_uri_copy(SoupURI* uri);
SoupURI* soup_uri_copy_host(SoupURI* uri);
int soup_uri_equal(SoupURI* uri1, SoupURI* uri2);
void soup_uri_free(SoupURI* uri);
const(char)* soup_uri_get_fragment(SoupURI* uri);
const(char)* soup_uri_get_host(SoupURI* uri);
const(char)* soup_uri_get_password(SoupURI* uri);
const(char)* soup_uri_get_path(SoupURI* uri);
uint soup_uri_get_port(SoupURI* uri);
const(char)* soup_uri_get_query(SoupURI* uri);
const(char)* soup_uri_get_scheme(SoupURI* uri);
const(char)* soup_uri_get_user(SoupURI* uri);
int soup_uri_host_equal(void* v1, void* v2);
uint soup_uri_host_hash(void* key);
void soup_uri_set_fragment(SoupURI* uri, const(char)* fragment);
void soup_uri_set_host(SoupURI* uri, const(char)* host);
void soup_uri_set_password(SoupURI* uri, const(char)* password);
void soup_uri_set_path(SoupURI* uri, const(char)* path);
void soup_uri_set_port(SoupURI* uri, uint port);
void soup_uri_set_query(SoupURI* uri, const(char)* query);
void soup_uri_set_query_from_fields(SoupURI* uri, const(char)* firstField, ... );
void soup_uri_set_query_from_form(SoupURI* uri, GHashTable* form);
void soup_uri_set_scheme(SoupURI* uri, const(char)* scheme);
void soup_uri_set_user(SoupURI* uri, const(char)* user);
char* soup_uri_to_string(SoupURI* uri, int justPathAndQuery);
int soup_uri_uses_default_port(SoupURI* uri);
char* soup_uri_decode(const(char)* part);
char* soup_uri_encode(const(char)* part, const(char)* escapeExtra);
char* soup_uri_normalize(const(char)* part, const(char)* unescapeExtra);
