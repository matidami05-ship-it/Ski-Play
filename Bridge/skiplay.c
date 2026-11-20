// Ski Play — thin C bridge between Swift and chiaki-ng's Remote Play library.
// SPDX-License-Identifier: AGPL-3.0-only

#include "skiplay.h"

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/session.h>
#include <chiaki/discovery.h>
#include <chiaki/regist.h>
#include <chiaki/controller.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/remote/holepunch.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static ChiakiLog global_log;
static SPLogCallback global_log_cb;
static void *global_log_user;

static void log_forward(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if(global_log_cb)
		global_log_cb((int)level, msg, global_log_user);
}

int sp_init(SPLogCallback log_cb, void *log_user)
{
	global_log_cb = log_cb;
	global_log_user = log_user;
	chiaki_log_init(&global_log, CHIAKI_LOG_ALL & ~(CHIAKI_LOG_VERBOSE | CHIAKI_LOG_DEBUG), log_forward, NULL);
	return (int)chiaki_lib_init();
}

const char *sp_error_string(int err)
{
	return chiaki_error_string((ChiakiErrorCode)err);
}

// MARK: - Discovery

struct sp_discovery_t
{
	ChiakiDiscovery discovery;
	ChiakiDiscoveryThread thread;
	SPHostCallback cb;
	void *user;
};

static void discovery_cb(ChiakiDiscoveryHost *host, void *user)
{
	SPDiscovery *d = user;
	if(!d->cb || !host)
		return;
	SPHost h;
	memset(&h, 0, sizeof(h));
	switch(host->state)
	{
		case CHIAKI_DISCOVERY_HOST_STATE_READY: h.state = 1; break;
		case CHIAKI_DISCOVERY_HOST_STATE_STANDBY: h.state = 2; break;
		default: h.state = 0; break;
	}
	h.ps5 = chiaki_discovery_host_is_ps5(host);
	h.addr = host->host_addr;
	h.name = host->host_name;
	h.host_id = host->host_id;
	h.host_type = host->host_type;
	h.system_version = host->system_version;
	h.running_app_name = host->running_app_name;
	h.running_app_titleid = host->running_app_titleid;
	d->cb(&h, d->user);
}

SPDiscovery *sp_discovery_new(SPHostCallback cb, void *user, int *err_out)
{
	SPDiscovery *d = calloc(1, sizeof(SPDiscovery));
	if(!d)
	{
		if(err_out) *err_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	d->cb = cb;
	d->user = user;
	ChiakiErrorCode err = chiaki_discovery_init(&d->discovery, &global_log, AF_INET);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		free(d);
		if(err_out) *err_out = err;
		return NULL;
	}
	err = chiaki_discovery_thread_start(&d->thread, &d->discovery, discovery_cb, d);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		chiaki_discovery_fini(&d->discovery);
		free(d);
		if(err_out) *err_out = err;
		return NULL;
	}
	if(err_out) *err_out = CHIAKI_ERR_SUCCESS;
	return d;
}

int sp_discovery_probe(SPDiscovery *d, const char *ipv4)
{
	if(!d || !ipv4)
		return CHIAKI_ERR_UNINITIALIZED;
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
#ifdef __APPLE__
	addr.sin_len = sizeof(addr);
#endif
	if(inet_pton(AF_INET, ipv4, &addr.sin_addr) != 1)
		return CHIAKI_ERR_PARSE_ADDR;

	ChiakiDiscoveryPacket packet;
	memset(&packet, 0, sizeof(packet));
	packet.cmd = CHIAKI_DISCOVERY_CMD_SRCH;

	packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS5;
	addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
	ChiakiErrorCode err = chiaki_discovery_send(&d->discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));

	packet.protocol_version = CHIAKI_DISCOVERY_PROTOCOL_VERSION_PS4;
	addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS4);
	ChiakiErrorCode err4 = chiaki_discovery_send(&d->discovery, &packet, (struct sockaddr *)&addr, sizeof(addr));
	return err == CHIAKI_ERR_SUCCESS ? err4 : err;
}

void sp_discovery_free(SPDiscovery *d)
{
	if(!d)
		return;
	chiaki_discovery_thread_stop(&d->thread);
	chiaki_discovery_fini(&d->discovery);
	free(d);
}

int sp_wakeup(const char *host, const char regist_key[16], bool ps5)
{
	// The wakeup credential is the regist key (an ASCII hex string) parsed as hex.
	char key[17];
	memcpy(key, regist_key, 16);
	key[16] = '\0';
	for(int i = 0; i < 16; i++)
	{
		if(key[i] == '\0')
			break;
		bool hex = (key[i] >= '0' && key[i] <= '9') || (key[i] >= 'a' && key[i] <= 'f') || (key[i] >= 'A' && key[i] <= 'F');
		if(!hex)
		{
			key[i] = '\0';
			break;
		}
	}
	uint64_t credential = strtoull(key, NULL, 16);
	return (int)chiaki_discovery_wakeup(&global_log, NULL, host, credential, ps5);
}

// MARK: - Registration

struct sp_regist_t
{
	ChiakiRegist regist;
	SPRegistCallback cb;
	void *user;
	bool ps5;
	char *host;
};

static void regist_cb(ChiakiRegistEvent *event, void *user)
{
	SPRegist *r = user;
	SPRegistResult result;
	memset(&result, 0, sizeof(result));
	result.ps5 = r->ps5;
	switch(event->type)
	{
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
		{
			ChiakiRegisteredHost *h = event->registered_host;
			result.status = 0;
			result.target = (int)h->target;
			result.ps5 = chiaki_target_is_ps5(h->target);
			memcpy(result.server_nickname, h->server_nickname, sizeof(result.server_nickname));
			result.server_nickname[sizeof(result.server_nickname) - 1] = '\0';
			memcpy(result.server_mac, h->server_mac, sizeof(result.server_mac));
			memcpy(result.rp_regist_key, h->rp_regist_key, sizeof(result.rp_regist_key));
			result.rp_key_type = h->rp_key_type;
			memcpy(result.rp_key, h->rp_key, sizeof(result.rp_key));
			result.console_pin = h->console_pin;
			break;
		}
		case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
			result.status = 2;
			break;
		default:
			result.status = 1;
			break;
	}
	if(r->cb)
		r->cb(&result, r->user);
}

SPRegist *sp_regist_start(const char *host, bool ps5, const uint8_t psn_account_id[8], uint32_t pin,
		SPRegistCallback cb, void *user, int *err_out)
{
	SPRegist *r = calloc(1, sizeof(SPRegist));
	if(!r)
	{
		if(err_out) *err_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	r->cb = cb;
	r->user = user;
	r->ps5 = ps5;
	r->host = strdup(host);

	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
	info.host = r->host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	info.rudp = NULL;

	ChiakiErrorCode err = chiaki_regist_start(&r->regist, &global_log, &info, regist_cb, r);
	if(err_out) *err_out = err;
	if(err != CHIAKI_ERR_SUCCESS)
	{
		free(r->host);
		free(r);
		return NULL;
	}
	return r;
}

void sp_regist_free(SPRegist *r)
{
	if(!r)
		return;
	chiaki_regist_stop(&r->regist);
	chiaki_regist_fini(&r->regist);
	free(r->host);
	free(r);
}

// MARK: - Session

struct sp_session_t
{
	ChiakiSession session;
	ChiakiOpusDecoder opus;
	SPCallbacks cb;
	bool started;
	ChiakiHolepunchSession holepunch;
	char remote_duid[65];
	bool ps5;
};

static void session_event_cb(ChiakiEvent *event, void *user)
{
	SPSession *s = user;
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			if(s->cb.connected) s->cb.connected(s->cb.user);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			if(s->cb.login_pin) s->cb.login_pin(s->cb.user, event->login_pin_request.pin_incorrect);
			break;
		case CHIAKI_EVENT_QUIT:
			if(s->cb.quit)
				s->cb.quit(s->cb.user, (int)event->quit.reason,
						event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason),
						chiaki_quit_reason_is_error(event->quit.reason));
			break;
		case CHIAKI_EVENT_RUMBLE:
			if(s->cb.rumble) s->cb.rumble(s->cb.user, event->rumble.left, event->rumble.right);
			break;
		case CHIAKI_EVENT_HOLEPUNCH:
			if(s->cb.holepunch) s->cb.holepunch(s->cb.user, event->data_holepunch.finished);
			break;
		default:
			break;
	}
}

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	SPSession *s = user;
	if(!s->cb.video)
		return true;
	return s->cb.video(s->cb.user, buf, buf_size, frames_lost, frame_recovered);
}

static void opus_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	SPSession *s = user;
	if(s->cb.audio_settings) s->cb.audio_settings(s->cb.user, channels, rate);
}

static void opus_frame_cb(int16_t *buf, size_t samples_count, void *user)
{
	SPSession *s = user;
	if(s->cb.audio_frame) s->cb.audio_frame(s->cb.user, buf, samples_count);
}

SPSession *sp_session_new(const SPSessionConfig *config, SPCallbacks callbacks, int *err_out)
{
	SPSession *s = calloc(1, sizeof(SPSession));
	if(!s)
	{
		if(err_out) *err_out = CHIAKI_ERR_MEMORY;
		return NULL;
	}
	s->cb = callbacks;
	s->ps5 = config->ps5;

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = config->ps5;
	info.host = config->host;
	memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
	memcpy(info.morning, config->morning, sizeof(info.morning));
	memcpy(info.psn_account_id, config->psn_account_id, sizeof(info.psn_account_id));
	info.video_profile.width = (unsigned int)config->width;
	info.video_profile.height = (unsigned int)config->height;
	info.video_profile.max_fps = (unsigned int)config->fps;
	info.video_profile.bitrate = (unsigned int)config->bitrate;
	info.video_profile.codec = (config->ps5 && config->codec == SP_CODEC_H265) ? CHIAKI_CODEC_H265 : CHIAKI_CODEC_H264;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = config->dualsense;
	info.audio_video_disabled = CHIAKI_NONE_DISABLED;
	info.auto_regist = false;
	info.holepunch_session = NULL;
	info.rudp_sock = NULL;
	if(config->psn_token && config->remote_duid)
	{
		s->holepunch = chiaki_holepunch_session_init(config->psn_token, &global_log);
		if(!s->holepunch)
		{
			free(s);
			if(err_out) *err_out = CHIAKI_ERR_UNINITIALIZED;
			return NULL;
		}
		if(config->port_guessing)
			chiaki_holepunch_session_force_port_guessing(s->holepunch, true);
		strncpy(s->remote_duid, config->remote_duid, sizeof(s->remote_duid) - 1);
		info.holepunch_session = s->holepunch;
		info.host = "";
	}
	info.packet_loss_max = config->packet_loss_max > 0 ? config->packet_loss_max : 0.05;
	info.enable_idr_on_fec_failure = true;

	ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &global_log);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		if(s->holepunch)
			chiaki_holepunch_session_fini(s->holepunch);
		free(s);
		if(err_out) *err_out = err;
		return NULL;
	}

	chiaki_opus_decoder_init(&s->opus, &global_log);
	chiaki_opus_decoder_set_cb(&s->opus, opus_settings_cb, opus_frame_cb, s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&s->opus, &sink);
	chiaki_session_set_audio_sink(&s->session, &sink);

	chiaki_session_set_event_cb(&s->session, session_event_cb, s);
	chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);

	if(err_out) *err_out = CHIAKI_ERR_SUCCESS;
	return s;
}

static int hexval(char c)
{
	if(c >= '0' && c <= '9') return c - '0';
	if(c >= 'a' && c <= 'f') return c - 'a' + 10;
	if(c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

int sp_session_connect_remote(SPSession *s)
{
	if(!s || !s->holepunch)
		return CHIAKI_ERR_UNINITIALIZED;
	uint8_t duid[32];
	size_t len = strlen(s->remote_duid);
	if(len != 64)
		return CHIAKI_ERR_INVALID_DATA;
	for(size_t i = 0; i < 32; i++)
	{
		int hi = hexval(s->remote_duid[2 * i]), lo = hexval(s->remote_duid[2 * i + 1]);
		if(hi < 0 || lo < 0)
			return CHIAKI_ERR_INVALID_DATA;
		duid[i] = (uint8_t)((hi << 4) | lo);
	}
	ChiakiHolepunchConsoleType type = s->ps5 ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4;
	ChiakiErrorCode err = chiaki_holepunch_upnp_discover(s->holepunch);
	if(err != CHIAKI_ERR_SUCCESS)
		CHIAKI_LOGW(&global_log, "UPnP discovery failed, continuing without it");
	err = chiaki_holepunch_session_create(s->holepunch);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "PSN: couldn't create session: %s", chiaki_error_string(err));
		return err;
	}
	err = holepunch_session_create_offer(s->holepunch);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "PSN: couldn't create offer: %s", chiaki_error_string(err));
		return err;
	}
	err = chiaki_holepunch_session_start(s->holepunch, duid, type);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "PSN: console didn't start the session: %s", chiaki_error_string(err));
		return err;
	}
	err = chiaki_holepunch_session_punch_hole(s->holepunch, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&global_log, "PSN: couldn't reach the console through the network: %s", chiaki_error_string(err));
		return err;
	}
	return CHIAKI_ERR_SUCCESS;
}

void sp_session_cancel_remote(SPSession *s)
{
	if(s && s->holepunch)
		chiaki_holepunch_main_thread_cancel(s->holepunch, true);
}

int sp_session_start(SPSession *s)
{
	ChiakiErrorCode err = chiaki_session_start(&s->session);
	s->started = err == CHIAKI_ERR_SUCCESS;
	return (int)err;
}

int sp_session_stop(SPSession *s)
{
	return (int)chiaki_session_stop(&s->session);
}

void sp_session_free(SPSession *s)
{
	if(!s)
		return;
	if(s->started)
	{
		chiaki_session_stop(&s->session);
		chiaki_session_join(&s->session);
	}
	chiaki_session_fini(&s->session);
	chiaki_opus_decoder_fini(&s->opus);
	free(s);
}

void sp_controller_idle(SPController *state)
{
	ChiakiControllerState c;
	chiaki_controller_state_set_idle(&c);
	memset(state, 0, sizeof(*state));
	state->touches[0].id = -1;
	state->touches[1].id = -1;
	state->gyro_x = c.gyro_x; state->gyro_y = c.gyro_y; state->gyro_z = c.gyro_z;
	state->accel_x = c.accel_x; state->accel_y = c.accel_y; state->accel_z = c.accel_z;
	state->orient_x = c.orient_x; state->orient_y = c.orient_y; state->orient_z = c.orient_z; state->orient_w = c.orient_w;
}

void sp_session_set_controller(SPSession *s, const SPController *in)
{
	if(!s || !in)
		return;
	ChiakiControllerState c;
	chiaki_controller_state_set_idle(&c);
	c.buttons = in->buttons;
	c.l2_state = in->l2;
	c.r2_state = in->r2;
	c.left_x = in->left_x;
	c.left_y = in->left_y;
	c.right_x = in->right_x;
	c.right_y = in->right_y;
	for(int i = 0; i < CHIAKI_CONTROLLER_TOUCHES_MAX && i < 2; i++)
	{
		c.touches[i].x = in->touches[i].x;
		c.touches[i].y = in->touches[i].y;
		c.touches[i].id = in->touches[i].id;
	}
	c.gyro_x = in->gyro_x; c.gyro_y = in->gyro_y; c.gyro_z = in->gyro_z;
	c.accel_x = in->accel_x; c.accel_y = in->accel_y; c.accel_z = in->accel_z;
	c.orient_x = in->orient_x; c.orient_y = in->orient_y; c.orient_z = in->orient_z; c.orient_w = in->orient_w;
	chiaki_session_set_controller_state(&s->session, &c);
}

void sp_session_set_login_pin(SPSession *s, const char *pin)
{
	if(!s || !pin)
		return;
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

int sp_session_request_idr(SPSession *s)
{
	return (int)chiaki_session_request_idr(&s->session);
}

int sp_session_sleep_console(SPSession *s)
{
	return (int)chiaki_session_goto_bed(&s->session);
}

uint64_t sp_session_rtt_us(SPSession *s)
{
	return s ? s->session.rtt_us : 0;
}

double sp_session_packet_loss(SPSession *s)
{
	return s ? s->session.stream_connection.congestion_control.packet_loss : 0;
}

double sp_session_measured_bitrate(SPSession *s)
{
	return s ? s->session.stream_connection.measured_bitrate : 0;
}

// MARK: - PlayStation Network

int sp_generate_duid(char *out, size_t out_size)
{
	size_t size = out_size;
	return (int)chiaki_holepunch_generate_client_device_uid(out, &size);
}

int sp_psn_list_devices(const char *psn_token, SPPsnDevice **devices_out)
{
	*devices_out = NULL;
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t count = 0;
	ChiakiErrorCode err = chiaki_holepunch_list_devices(psn_token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &global_log);
	if(err != CHIAKI_ERR_SUCCESS)
		return -(int)err;
	SPPsnDevice *out = calloc(count ? count : 1, sizeof(SPPsnDevice));
	if(!out)
	{
		chiaki_holepunch_free_device_list(&devices);
		return -(int)CHIAKI_ERR_MEMORY;
	}
	for(size_t i = 0; i < count; i++)
	{
		memcpy(out[i].name, devices[i].device_name, sizeof(out[i].name));
		out[i].name[sizeof(out[i].name) - 1] = '\0';
		for(size_t b = 0; b < sizeof(devices[i].device_uid); b++)
			snprintf(out[i].duid + 2 * b, 3, "%02x", devices[i].device_uid[b]);
		out[i].ps5 = devices[i].type == CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5;
		out[i].remoteplay_enabled = devices[i].remoteplay_enabled;
	}
	if(devices)
		chiaki_holepunch_free_device_list(&devices);
	*devices_out = out;
	return (int)count;
}
