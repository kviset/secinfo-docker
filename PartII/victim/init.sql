USE production;

CREATE TABLE IF NOT EXISTS flag (
  `id` int(11) NOT NULL auto_increment,
  `message`  varchar(100) NOT NULL default '',
  PRIMARY KEY (id)
);

INSERT INTO flag (message) VALUES ("Flag captured");
