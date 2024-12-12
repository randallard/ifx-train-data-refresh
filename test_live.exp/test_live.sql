{ DATABASE test_live  delimiter | }

grant dba to "informix";











{ TABLE "informix".customers row size = 429 number of columns = 6 index size = 0 }

{ unload file name = custo00100.unl number of rows = 73 }

create table "informix".customers 
  (
    id serial not null ,
    first_name varchar(50),
    last_name varchar(50),
    email varchar(100),
    address varchar(200),
    phone varchar(20)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".customers from "public" as "informix";

{ TABLE "informix".employees row size = 432 number of columns = 6 index size = 0 }

{ unload file name = emplo00101.unl number of rows = 53 }

create table "informix".employees 
  (
    id serial not null ,
    customer_id integer,
    name varchar(100),
    email varchar(100),
    address varchar(200),
    phone varchar(20)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".employees from "public" as "informix";

{ TABLE "informix".projects row size = 362 number of columns = 6 index size = 0 }

{ unload file name = proje00102.unl number of rows = 74 }

create table "informix".projects 
  (
    id serial not null ,
    customer_id integer,
    project_name varchar(100),
    name1 varchar(50),
    name2 varchar(50),
    combo_name varchar(150)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".projects from "public" as "informix";

{ TABLE "informix".repositories row size = 261 number of columns = 5 index size = 0 }

{ unload file name = repos00103.unl number of rows = 74 }

create table "informix".repositories 
  (
    id serial not null ,
    project_id integer,
    owner_name varchar(50),
    repo_name varchar(50),
    full_path varchar(150)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".repositories from "public" as "informix";

{ TABLE "informix".training_config row size = 256 number of columns = 3 index size = 0 }

{ unload file name = train00104.unl number of rows = 10 }

create table "informix".training_config 
  (
    id serial not null ,
    config_key varchar(50),
    config_value varchar(200)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".training_config from "public" as "informix";

{ TABLE "informix".train_specific_data row size = 311 number of columns = 3 index size = 0 }

{ unload file name = train00105.unl number of rows = 10 }

create table "informix".train_specific_data 
  (
    id serial not null ,
    data_key varchar(50),
    data_value varchar(255)
  ) extent size 16 next size 16 lock mode row;

revoke all on "informix".train_specific_data from "public" as "informix";




grant select on "informix".customers to "public" as "informix";
grant update on "informix".customers to "public" as "informix";
grant insert on "informix".customers to "public" as "informix";
grant delete on "informix".customers to "public" as "informix";
grant index on "informix".customers to "public" as "informix";
grant select on "informix".employees to "public" as "informix";
grant update on "informix".employees to "public" as "informix";
grant insert on "informix".employees to "public" as "informix";
grant delete on "informix".employees to "public" as "informix";
grant index on "informix".employees to "public" as "informix";
grant select on "informix".projects to "public" as "informix";
grant update on "informix".projects to "public" as "informix";
grant insert on "informix".projects to "public" as "informix";
grant delete on "informix".projects to "public" as "informix";
grant index on "informix".projects to "public" as "informix";
grant select on "informix".repositories to "public" as "informix";
grant update on "informix".repositories to "public" as "informix";
grant insert on "informix".repositories to "public" as "informix";
grant delete on "informix".repositories to "public" as "informix";
grant index on "informix".repositories to "public" as "informix";
grant select on "informix".training_config to "public" as "informix";
grant update on "informix".training_config to "public" as "informix";
grant insert on "informix".training_config to "public" as "informix";
grant delete on "informix".training_config to "public" as "informix";
grant index on "informix".training_config to "public" as "informix";
grant select on "informix".train_specific_data to "public" as "informix";
grant update on "informix".train_specific_data to "public" as "informix";
grant insert on "informix".train_specific_data to "public" as "informix";
grant delete on "informix".train_specific_data to "public" as "informix";
grant index on "informix".train_specific_data to "public" as "informix";















revoke usage on language SPL from public ;

grant usage on language SPL to public ;













 



