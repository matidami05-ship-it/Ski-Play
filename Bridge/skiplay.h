// Ski Play — thin C bridge between Swift and chiaki-ng's Remote Play library.
// SPDX-License-Identifier: AGPL-3.0-only

#ifndef SKIPLAY_H
#define SKIPLAY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*SPLogCallback)(int level, const char *msg, void *user);

/// Initializes the library. Call once at app start.
int sp_init(SPLogCallback log_cb, void *log_user);
const char *sp_error_string(int err);

// MARK: - Discovery

typedef struct sp_host_t
{
	int state; // 0 unknown, 1 ready (on), 2 standby (rest mode)
	bool ps5;
	const char *addr;
	const char *name;
	const char *host_id;
	const char *host_type;
	const char *system_version;
	const char *running_app_name;
	const char *running_app_titleid;
} SPHost;

typedef void (*SPHostCallback)(const SPHost *host, void *user);

typedef struct sp_discovery_t SPDiscovery;

/// Opens a discovery socket and starts listening for console replies.
SPDiscovery *sp_discovery_new(SPHostCallback cb, void *user, int *err_out);
/// Sends a search packet (PS4 and PS5) to one IPv4 address.
int sp_discovery_probe(SPDiscovery *discovery, const char *ipv4);
void sp_discovery_free(SPDiscovery *discovery);

/// Wakes a console from rest mode. regist_key is the 16-byte key from registration.
int sp_wakeup(const char *host, const char regist_key[16], bool ps5);

// MARK: - Registration (linking with the console's PIN)

typedef struct sp_regist_result_t
{
	int status; // 0 success, 1 failed, 2 canceled
	bool ps5;
	int target;
	char server_nickname[0x20];
	uint8_t server_mac[6];
	char rp_regist_key[16];
	uint32_t rp_key_type;
	uint8_t rp_key[16];
	uint32_t console_pin;
} SPRegistResult;

typedef void (*SPRegistCallback)(const SPRegistResult *result, void *user);

typedef struct sp_regist_t SPRegist;

SPRegist *sp_regist_start(const char *host, bool ps5, const uint8_t psn_account_id[8], uint32_t pin,
		SPRegistCallback cb, void *user, int *err_out);
void sp_regist_free(SPRegist *regist);

// MARK: - Streaming session

enum
{
	SP_CODEC_H264 = 0,
	SP_CODEC_H265 = 1
};

typedef struct sp_session_config_t
{
	const char *host;
	bool ps5;
	char regist_key[16];
	uint8_t morning[16];
	uint8_t psn_account_id[8];
	int width;
	int height;
	int fps;
	int bitrate; // kbit/s
	int codec;
	bool dualsense;
	double packet_loss_max;
} SPSessionConfig;

typedef struct sp_callbacks_t
{
	void *user;
	void (*connected)(void *user);
	void (*quit)(void *user, int reason, const char *reason_str, bool is_error);
	void (*login_pin)(void *user, bool incorrect);
	void (*rumble)(void *user, uint8_t left, uint8_t right);
	bool (*video)(void *user, const uint8_t *buf, size_t size, int32_t frames_lost, bool frame_recovered);
	void (*audio_settings)(void *user, uint32_t channels, uint32_t rate);
	void (*audio_frame)(void *user, const int16_t *pcm, size_t samples_count);
} SPCallbacks;

typedef struct sp_touch_t
{
	uint16_t x, y;
	int8_t id; // -1 = not touching
} SPTouch;

typedef struct sp_controller_t
{
	uint32_t buttons; // ChiakiControllerButton bits
	uint8_t l2;
	uint8_t r2;
	int16_t left_x, left_y, right_x, right_y;
	SPTouch touches[2];
	float gyro_x, gyro_y, gyro_z;
	float accel_x, accel_y, accel_z;
	float orient_x, orient_y, orient_z, orient_w;
} SPController;

typedef struct sp_session_t SPSession;

SPSession *sp_session_new(const SPSessionConfig *config, SPCallbacks callbacks, int *err_out);
int sp_session_start(SPSession *session);
int sp_session_stop(SPSession *session);
/// Joins the session thread and frees everything. Call after quit.
void sp_session_free(SPSession *session);
void sp_session_set_controller(SPSession *session, const SPController *state);
void sp_session_set_login_pin(SPSession *session, const char *pin);
int sp_session_request_idr(SPSession *session);
int sp_session_sleep_console(SPSession *session);
void sp_controller_idle(SPController *state);

/// Measured round-trip time in microseconds (0 if unknown).
uint64_t sp_session_rtt_us(SPSession *session);
/// Current reported packet loss (0..1).
double sp_session_packet_loss(SPSession *session);
/// Bitrate in Mbit/s the console is currently sending.
double sp_session_measured_bitrate(SPSession *session);

#ifdef __cplusplus
}
#endif

#endif
