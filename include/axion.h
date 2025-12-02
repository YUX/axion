#ifndef AXION_H
#define AXION_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Opaque handle to an Axion database instance.
 */
typedef struct axion_db_t axion_db_t;

/**
 * @brief Opaque handle to an Axion iterator.
 */
typedef struct axion_iter_t axion_iter_t;

/**
 * @brief Opaque handle to database options.
 */
typedef struct axion_options_t axion_options_t;

/**
 * @brief Creates a default options object.
 * 
 * @param out_opts Pointer to receive the options handle.
 * @return 0 on success, non-zero on error.
 */
int axion_options_create(axion_options_t** out_opts);

/**
 * @brief Destroys an options object.
 * 
 * @param opts Options handle.
 */
void axion_options_destroy(axion_options_t* opts);

/**
 * @brief Sets the MemTable size in bytes.
 * 
 * @param opts Options handle.
 * @param size Size in bytes.
 */
void axion_options_set_memtable_size(axion_options_t* opts, size_t size);

/**
 * @brief Sets the L0 file limit (trigger for compaction).
 * 
 * @param opts Options handle.
 * @param limit Number of files.
 */
void axion_options_set_l0_limit(axion_options_t* opts, size_t limit);

/**
 * @brief Opens or creates an Axion database.
 * 
 * @param path Directory path for the database.
 * @param out_db Pointer to receive the database handle.
 * @return 0 on success, non-zero on error.
 */
int axion_db_open(const char* path, axion_db_t** out_db);

/**
 * @brief Opens or creates an Axion database with custom options.
 * 
 * @param path Directory path for the database.
 * @param opts Options handle.
 * @param out_db Pointer to receive the database handle.
 * @return 0 on success, non-zero on error.
 */
int axion_db_open_with_options(const char* path, axion_options_t* opts, axion_db_t** out_db);

/**
 * @brief Closes the database and frees resources.
 * 
 * @param db Database handle.
 */
void axion_db_close(axion_db_t* db);

/**
 * @brief Writes a key-value pair to the database.
 * 
 * @param db Database handle.
 * @param key Key data.
 * @param key_len Length of the key.
 * @param val Value data.
 * @param val_len Length of the value.
 * @return 0 on success, non-zero on error.
 */
int axion_db_put(axion_db_t* db, const char* key, size_t key_len, const char* val, size_t val_len);

/**
 * @brief Retrieves a value from the database.
 * 
 * @note The returned value in `out_val` is allocated by the database and MUST be freed 
 *       using `axion_db_free_val`.
 * 
 * @param db Database handle.
 * @param key Key data.
 * @param key_len Length of the key.
 * @param out_val Pointer to receive the value buffer. If not found, *out_val is NULL.
 * @param out_val_len Pointer to receive the value length.
 * @return 0 on success (found or not found), non-zero on error.
 */
int axion_db_get(axion_db_t* db, const char* key, size_t key_len, char** out_val, size_t* out_val_len);

/**
 * @brief Frees a value buffer returned by `axion_db_get`.
 * 
 * @param val Pointer to the value buffer.
 * @param len Length of the value buffer.
 */
void axion_db_free_val(char* val, size_t len);

/**
 * @brief Deletes a key from the database.
 * 
 * @param db Database handle.
 * @param key Key data.
 * @param key_len Length of the key.
 * @return 0 on success, non-zero on error.
 */
int axion_db_delete(axion_db_t* db, const char* key, size_t key_len);

// Iterator Operations

/**
 * @brief Creates a new iterator for the database.
 * 
 * @note The iterator creates a snapshot of the database state at the time of creation.
 * 
 * @param db Database handle.
 * @param out_iter Pointer to receive the iterator handle.
 * @return 0 on success, non-zero on error.
 */
int axion_c_iter_create(axion_db_t* db, axion_iter_t** out_iter);

/**
 * @brief Destroys an iterator.
 * 
 * @param iter Iterator handle.
 */
void axion_c_iter_destroy(axion_iter_t* iter);

/**
 * @brief Seeks the iterator to the first key >= `key`.
 * 
 * @param iter Iterator handle.
 * @param key Key to seek to.
 * @param key_len Length of the key.
 * @return 0 on success, non-zero on error.
 */
int axion_c_iter_seek(axion_iter_t* iter, const char* key, size_t key_len);

/**
 * @brief Checks if the iterator is currently valid (points to a valid entry).
 * 
 * @param iter Iterator handle.
 * @return true if valid, false otherwise.
 */
bool axion_c_iter_valid(axion_iter_t* iter);

/**
 * @brief Advances the iterator to the next key.
 * 
 * @param iter Iterator handle.
 * @return 0 on success, non-zero on error.
 */
int axion_c_iter_next(axion_iter_t* iter);

/**
 * @brief Gets the current key.
 * 
 * @note The returned pointer is valid ONLY until the next call to `axion_c_iter_next`, 
 *       `axion_c_iter_seek`, or `axion_c_iter_destroy`.
 * 
 * @param iter Iterator handle.
 * @param out_len Pointer to receive the key length.
 * @return Pointer to the key data, or NULL if iterator is invalid.
 */
const char* axion_c_iter_key(axion_iter_t* iter, size_t* out_len);

/**
 * @brief Gets the current value.
 * 
 * @note The returned pointer is valid ONLY until the next call to `axion_c_iter_next`, 
 *       `axion_c_iter_seek`, or `axion_c_iter_destroy`.
 * 
 * @param iter Iterator handle.
 * @param out_len Pointer to receive the value length.
 * @return Pointer to the value data, or NULL if iterator is invalid.
 */
const char* axion_c_iter_value(axion_iter_t* iter, size_t* out_len);

#ifdef __cplusplus
}
#endif

#endif // AXION_H