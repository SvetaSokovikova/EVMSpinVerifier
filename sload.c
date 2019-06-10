#include <jansson.h>
#include <curl/curl.h>

#define BUFFER_SIZE  (256 * 1024)  /* 256 KB */

struct write_result
{
    char *data;
    int pos;
};

static size_t write_response(void *ptr, size_t size, size_t nmemb, void *stream)
{
    struct write_result *result = (struct write_result *)stream;

    if(result->pos + size * nmemb >= BUFFER_SIZE - 1)
    {
        fprintf(stderr, "error: too small buffer\n");
        return 0;
    }

    memcpy(result->data + result->pos, ptr, size * nmemb);
    result->pos += size * nmemb;

    return size * nmemb;
}

static char *request(const char *address, const char *key)
{
    CURL *curl = NULL;
    CURLcode status;
    struct curl_slist *headers = NULL;
    char *data = NULL;
    long code;
	
	char url[22] = "http://127.0.0.1:8545/";

    curl_global_init(CURL_GLOBAL_ALL);
    curl = curl_easy_init();
    if(!curl)
        goto error;

    data = malloc(BUFFER_SIZE);
    if(!data)
        goto error;

    struct write_result write_result = {
        .data = data,
        .pos = 0
    };

    curl_easy_setopt(curl, CURLOPT_URL, url);

    headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_response);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &write_result);
	
	char postfields[194] = "{\"jsonrpc\":\"2.0\", \"method\": \"eth_getStorageAt\", \"id\": 1, \"params\":[\"";
	short i;
	for (i = 0; i < 42; i++)
	{
		postfields[68 + i] = address[i];
	};
	postfields[110] = '"';
	postfields[111] = ',';
	postfields[112] = ' ';
	postfields[113] = '"';
	for (i = 0; i < 66; i++)
	{
		postfields[114 + i] = key[i];
	};
	postfields[180] = '"';
	postfields[181] = ',';
	postfields[182] = ' ';
	char latest[10] = "\"latest\"]}";
	for (i = 0; i < 10; i++)
	{
		postfields[183 + i] = latest[i];
	};
	postfields[193] = '\0';
	
	curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 194);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, postfields);

    status = curl_easy_perform(curl);
    if(status != 0)
    {
        fprintf(stderr, "error: unable to request data from %s:\n", url);
        fprintf(stderr, "%s\n", curl_easy_strerror(status));
        goto error;
    }

    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    if(code != 200)
    {
        fprintf(stderr, "error: server responded with code %ld\n", code);
        goto error;
    }

    curl_easy_cleanup(curl);
    curl_slist_free_all(headers);
    curl_global_cleanup();

    /* zero-terminate the result */
    data[write_result.pos] = '\0';

    return data;

error:
    if(data)
        free(data);
    if(curl)
        curl_easy_cleanup(curl);
    if(headers)
        curl_slist_free_all(headers);
    curl_global_cleanup();
    return NULL;
}


static unsigned char *sequence(char *s)
{
	char charBuf[3];
	unsigned char i;
	static unsigned char bytes[32];
	
	for (i = 1; i <= 32; i++)
	{
		charBuf[0] = s[2*i];
		charBuf[1] = s[2*i+1];
		charBuf[2] = '\0';
		bytes[i-1] = (unsigned char)strtol(charBuf, NULL, 16);
	};
	
	return bytes;
}


unsigned char *load(const char *address, const char *key)
{
	char *text;
    json_t *root;
    json_error_t error;
	
	static unsigned char *bytes = NULL;

    text = request(address, key);
    if(!text)
        return bytes;

    root = json_loads(text, 0, &error);
    free(text);
	
    if(!root)
    {
        fprintf(stderr, "error: on line %d: %s\n", error.line, error.text);
        return bytes;
    }
	
	json_t *result;
	
	result = json_object_get(root, "result");
	if(!json_is_string(result))
	{
		fprintf(stderr, "error: storage item is not a string\n");
		return bytes;
	}
	
	char *resultString = json_string_value(result);
    json_decref(root);
	
	bytes = sequence(resultString);
	return bytes;
}