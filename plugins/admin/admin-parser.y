%token_prefix TK_

%token_type {token_t}
%default_type {token_t}

%extra_argument {struct network_mysqld_con *con}

%syntax_error {
  UNUSED_PARAMETER(yymajor);  /* Silence some compiler warnings */
  admin_syntax_error(con);
}

%stack_overflow {
  admin_stack_overflow(con);
}

%name adminParser

%include {
#include <assert.h>
#include <inttypes.h>
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include "admin-parser.y.h"
#include "admin-commands.h"
#include "sharding-config.h"

struct network_mysqld_con;

#define UNUSED_PARAMETER(x) (void)(x)
#define YYNOERRORRECOVERY 1
#define YYPARSEFREENEVERNULL 1
#define YYMALLOCARGTYPE  uint64_t

typedef struct equation_t {
  token_t left;
  token_t right;
} equation_t;

static int64_t token2int(token_t token)
{
    /*TODO: HEX*/
    int64_t value = 0;
    int sign = 1;
    const char* c = token.z;
    int i = 0;
    if( *c == '+' || *c == '-' ) {
        if( *c == '-' ) sign = -1;
        c++;
        i++;
    }
    while (isdigit(*c) && i++ < token.n) {
        value *= 10;
        value += (int) (*c-'0');
        c++;
    }
    return (value * sign);
}

static void string_dequote(char* z)
{
    int quote;
    int i, j;
    if( z==0 ) return;
    quote = z[0];
    switch( quote ){
    case '\'':  break;
    case '"':   break;
    case '`':   break;                /* For MySQL compatibility */
    default:    return;
    }
    for (i=1, j=0; z[i]; i++) {
        if (z[i] == quote) {
            if (z[i+1]==quote) { /*quote escape*/
                z[j++] = quote;
                i++;
            } else {
                z[j++] = 0;
                break;
            }
        } else if (z[i] == '\\') { /* slash escape */
            i++;
            z[j++] = z[i];
        } else {
            z[j++] = z[i];
        }
    }
}

static char* token_strdup(token_t token)
{
    if (token.n == 0)
        return NULL;
    char* s = malloc(token.n + 1);
    memcpy(s, token.z, token.n);
    s[token.n] = '\0';
    string_dequote(s);
    return s;
}

} // end %include

input ::= cmd.

%left OR.
%left AND.
%right NOT.
%left LIKE NE EQ.
%left GT LE LT GE.

%fallback ID
  CONN_DETAILS BACKENDS AT_SIGN REDUCE_CONNS ADD MAINTAIN STATUS
  CONN_NUM BACKEND_NDX RESET CETUS VDB HASH RANGE SHARDKEY
  .

%wildcard ANY.

%type opt_where_user {char*}
%destructor opt_where_user {free($$);}
opt_where_user(A) ::= WHERE USER EQ STRING(E). {A = token_strdup(E);}
opt_where_user(A) ::= . {A = NULL;}

%type equation {equation_t*}
%destructor equation {free($$);}
equation(A) ::= ID(X) EQ STRING|ID|INTEGER|FLOAT(Y). {
  A = calloc(1, sizeof(equation_t));
  A->left = X;
  A->right = Y;
}

%type opt_like {char*}
%destructor opt_like {free($$);}
opt_like(A) ::= LIKE STRING(X). {A = token_strdup(X);}
opt_like(A) ::= . {A = NULL; }

%type boolean {int}
boolean(A) ::= TRUE. {A = 1;}
boolean(A) ::= FALSE. {A = 0;}
boolean(A) ::= INTEGER(X). {A = token2int(X)==0 ? 0:1;}

%type opt_integer {int}
opt_integer(A) ::= . {A = -1;}
opt_integer(A) ::= INTEGER(X). {A = token2int(X);}

%token_class ids STRING|ID.

cmd ::= SELECT CONN_DETAILS FROM BACKENDS. {
  admin_select_conn_details(con);
}
cmd ::= SELECT STAR FROM BACKENDS. {
  admin_select_all_backends(con);
}
cmd ::= SELECT STAR FROM GROUPS. {
  admin_select_all_groups(con);
}
cmd ::= SHOW CONNECTIONLIST opt_integer(X). {
  admin_show_connectionlist(con, X);
}
cmd ::= SHOW ALLOW_IP ids(X). {
  char* module = token_strdup(X);
  admin_show_allow_ip(con, module);
  free(module);
}
cmd ::= ADD ALLOW_IP ids(X) STRING(Y). {
  char* module = token_strdup(X);
  char* ip = token_strdup(Y);
  admin_add_allow_ip(con, module, ip);
  free(module);
  free(ip);
}
cmd ::= DELETE ALLOW_IP ids(X) STRING(Y). {
  char* module = token_strdup(X);
  char* ip = token_strdup(Y);
  admin_delete_allow_ip(con, module, ip);
  free(module);
  free(ip);
}
cmd ::= SET REDUCE_CONNS boolean(X). {
  admin_set_reduce_conns(con, X);
}
cmd ::= SET MAINTAIN boolean(X). {
  admin_set_maintain(con, X);
}
cmd ::= SHOW STATUS opt_like(X). {
  admin_show_status(con, X);
  if (X) free(X);
}
cmd ::= SHOW VARIABLES opt_like(X). {
  admin_show_variables(con, X);
  if (X) free(X);
}
cmd ::= SELECT VERSION. {
  admin_select_version(con);
}
cmd ::= SELECT CONN_NUM FROM BACKENDS WHERE BACKEND_NDX EQ INTEGER(X) AND USER EQ STRING(Y). {
  char* user = token_strdup(Y);
  admin_select_connection_stat(con, token2int(X), user);
  free(user);
}
cmd ::= SELECT STAR FROM USER_PWD|APP_USER_PWD(T) opt_where_user(X). {
  char* table = (@T == TK_USER_PWD)?"user_pwd":"app_user_pwd";
  admin_select_user_password(con, table, X);
  if (X) free(X);
}
cmd ::= UPDATE USER_PWD|APP_USER_PWD(T) SET PASSWORD EQ STRING(P) WHERE USER EQ STRING(U). {
  char* table = (@T == TK_USER_PWD)?"user_pwd":"app_user_pwd";
  char* user = token_strdup(U);
  char* pass = token_strdup(P);
  admin_update_user_password(con, table, user, pass);
  free(user);
  free(pass);
}
cmd ::= DELETE FROM USER_PWD|APP_USER_PWD WHERE USER EQ STRING(U). {
  char* user = token_strdup(U);
  admin_delete_user_password(con, user);
  free(user);
}
cmd ::= INSERT INTO BACKENDS VALUES LP STRING(X) COMMA STRING(Y) COMMA STRING(Z) RP. {
  char* addr = token_strdup(X);
  char* type = token_strdup(Y);
  char* state = token_strdup(Z);
  admin_insert_backend(con, addr, type, state);
  free(addr); free(type); free(state);
}
cmd ::= UPDATE BACKENDS SET equation(X) COMMA equation(Y) WHERE equation(Z). {
//TODO: equation list
  char* key1 = token_strdup(X->left);
  char* val1 = token_strdup(X->right);
  char* key2 = token_strdup(Y->left);
  char* val2 = token_strdup(Y->right);
  char* cond_key = token_strdup(Z->left);
  char* cond_val = token_strdup(Z->right);
  admin_update_backend(con, key1, val1, key2, val2, cond_key, cond_val);
  free(key1); free(val1);
  free(key2); free(val2);
  free(cond_key); free(cond_val);
  free(X); free(Y);
}
cmd ::= DELETE FROM BACKENDS WHERE equation(Z). {
  char* key = token_strdup(Z->left);
  char* val = token_strdup(Z->right);
  admin_delete_backend(con, key, val);
  free(key);
  free(val);
  free(Z);
}
cmd ::= ADD MASTER STRING(X). {
  char* addr = token_strdup(X);
  admin_insert_backend(con, addr, "rw", "unknown");
  free(addr);
}
cmd ::= ADD SLAVE STRING(X). {
  char* addr = token_strdup(X);
  admin_insert_backend(con, addr, "ro", "unknown");
  free(addr);
}
cmd ::= STATS GET opt_id(X). {
  admin_get_stats(con, X);
  if (X) free(X);
}
cmd ::= CONFIG GET opt_id(X). {
  admin_get_config(con, X);
  if (X) free(X);
}
cmd ::= CONFIG SET equation(X). {
  char* key = token_strdup(X->left);
  char* val = token_strdup(X->right);
  admin_set_config(con, key, val);
  free(key);
  free(val);
}
cmd ::= STATS RESET. {
  admin_reset_stats(con);
}
cmd ::= SELECT STAR FROM HELP. {
  admin_select_help(con);
}
cmd ::= SELECT HELP. {
  admin_select_help(con);
}
cmd ::= CETUS. {
  admin_send_overview(con);
}

%include {
struct vdb_method {
  enum sharding_method_t method;
  int key_type;
  int logic_shard_num;
};

} //end %include

cmd ::= CREATE VDB INTEGER(X) LP partitions(Y) RP USING method(Z). {
  admin_create_vdb(con, token2int(X), Y, Z.method, Z.key_type, Z.logic_shard_num);
  g_ptr_array_free(Y, TRUE);
}

%type int_array_prefix {GArray*}
%type int_array {GArray*}
%destructor int_array_prefix {g_array_free($$, TRUE);}
%destructor int_array {g_array_free($$, TRUE);}
int_array_prefix(A) ::= int_array(A) COMMA.
int_array_prefix(A) ::= . { A = NULL; }
int_array(A) ::= int_array_prefix(X) INTEGER(Y). {
  if (X == NULL) {
    A = g_array_new(0,0,sizeof(int32_t));
  } else {
    A = X;
  }
  int32_t n = token2int(Y);
  g_array_append_val(A, n);
}

%type partition {sharding_partition_t*}
%destructor partition {sharding_partition_free($$);}
partition(A) ::= ids(X) COLON LBRACKET int_array(Y) RBRACKET. {
  A = g_new0(sharding_partition_t, 1);
  A->group_name = g_string_new_len(X.z, X.n);
  A->key_type = SHARD_DATA_TYPE_INT;
  A->method = SHARD_METHOD_HASH;
  int i;
  for (i = 0; i < Y->len; ++i) {
    int32_t val = g_array_index(Y, int, i);
    SetBit(A->hash_set, val);
  }
  g_array_free(Y, TRUE);
}
partition(A) ::= ids(X) COLON ids(Y). {
  A = g_new0(sharding_partition_t, 1);
  A->group_name = g_string_new_len(X.z, X.n);
  A->method = SHARD_METHOD_RANGE;
  A->value = token_strdup(Y);
}
partition(A) ::= ids(X) COLON INTEGER(Y). {
  A = g_new0(sharding_partition_t, 1);
  A->group_name = g_string_new_len(X.z, X.n);
  A->value = (void*)(int64_t)token2int(Y);
}

%type partitions_prefix {GPtrArray*}
%type partitions {GPtrArray*}
%destructor partitions_prefix {g_ptr_array_free($$, TRUE);}
%destructor partitions {g_ptr_array_free($$, TRUE);}
partitions_prefix(A) ::= partitions(A) COMMA.
partitions_prefix(A) ::= . { A = NULL;}
partitions(A) ::= partitions_prefix(X) partition(Y). {
  if (X == NULL) {
    A = g_ptr_array_new();
  } else {
    A = X;
  }
  g_ptr_array_add(A, Y);
}

%type opt_id {char*}
%destructor opt_id {free($$);}
opt_id(A) ::= ID(X). { A = token_strdup(X); }
opt_id(A) ::= . {A=0;}

%type method {struct vdb_method}
method(A) ::= HASH LP ID(X) COMMA INTEGER(Y) RP. {
  A.method = SHARD_METHOD_HASH;
  A.logic_shard_num = token2int(Y);
  char* key = token_strdup(X);
  A.key_type = sharding_key_type(key);
  g_free(key);
}
method(A) ::= RANGE LP ID(X) RP. {
  A.method = SHARD_METHOD_RANGE;
  A.logic_shard_num = 0;
  char* key = token_strdup(X);
  A.key_type = sharding_key_type(key);
  g_free(key);
}

cmd ::= CREATE SHARDED TABLE ids(X) DOT ids(Y) VDB INTEGER(Z) SHARDKEY ids(W). {
  char* schema = token_strdup(X);
  char* table = token_strdup(Y);
  char* key = token_strdup(W);
  admin_create_sharded_table(con, schema, table, key, token2int(Z));
  g_free(schema);
  g_free(table);
  g_free(key);
}

cmd ::= SELECT STAR FROM VDB. {
  admin_select_vdb(con);
}

cmd ::= SELECT SHARDED TABLE. {
  admin_select_sharded_table(con);
}