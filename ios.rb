# Nokia SMS Converter
# Copyright (c) 2011, Richard Z.H. Wang <http://zhwang.me/>

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Nokia db structure:
# CREATE TABLE MessageEx (
#   GUID CHAR(38) PRIMARY KEY ,
#   "MessageUUID" VARCHAR ,
#   "Text" VARCHAR ,
#   "Coding" INTEGER ,
#   "Body" VARCHAR ,
#   "Sender" VARCHAR , -> The receiver takes up this column if it's a sent text (nice work Nokia)
#   "Receiver" VARCHAR , -> Not used.
#   "Type" VARCHAR ,
#   "Direction" INTEGER ,
#   "Status" INTEGER , -> 5 = sent, 36 = received
#   "IMEI" VARCHAR ,
#   "SentReceivedTimestamp" REAL
# )

require "date"
require "rubygems"
require "sqlite3"

@messages = nil

def msgcol(column_name)
  return @messages.first.index column_name
end
def utftoascii(str)
  return str.unpack("U*").map{|c|c.chr}.join
end

def get_iosdb_location
  puts "Where is your iOS sms.db located?"
  
  # Thanks to mankoff for this info! http://apple.stackexchange.com/q/2535/2539#2539
  puts "You can grab it off a jailbroken iOS device by SSHing to /var/mobile/Library/SMS/sms.db"
  puts "Otherwise, you can try looking in ~/Library/Application Support/MobileSync/Backup/"
  
  puts
  iosdb_location = gets.strip
  puts
  
  if not File.exists? iosdb_location
    puts "The location you provided doesn't exist!"
    puts
    get_iosdb_location
  end
  
  return iosdb_location
end

def convert_to_ios
  #puts
  #iosdb = SQLite3::Database.new get_iosdb_location
  
  puts
  puts "What country code should these texts be? e.g. \"au\" for Australia"
  puts "Of course you can always edit the database yourself later if what you enter doesn't apply to all of them"
  puts
  
  country = gets.strip
  
  puts
  
  # iOS messages structure:
  # CREATE TABLE message (
  #   ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
  #   address TEXT,
  #   date INTEGER, -> A Unix timestamp.
  #   text TEXT,
  #   flags INTEGER, -> 2 = received, 3 = sent, 33 = message send failure, 129 = deleted
  #   replace INTEGER,
  #   svc_center TEXT,
  #   group_id INTEGER,
  #   association_id INTEGER,
  #   height INTEGER,
  #   UIFlags INTEGER, -> TODO: FIND OUT WHAT THIS IS MEANT TO DO
  #   version INTEGER,
  #   subject TEXT,
  #   country TEXT,
  #   headers BLOB,
  #   recipients BLOB,
  #   read INTEGER
  # )
  
  people = [] # Or in other words "groups"
  newest_message_for_person = {}
  
  # Some triggers that are needed for the inserts to work. Thanks to viper_88 - http://stackoverflow.com/q/3458314
  string = "drop trigger insert_unread_message;
drop trigger mark_message_unread;
drop trigger mark_message_read;
drop trigger delete_message;
CREATE TRIGGER insert_unread_message AFTER INSERT ON message WHEN NOT new.flags = 2 BEGIN UPDATE msg_group SET unread_count = (SELECT unread_count FROM msg_group WHERE ROWID = new.group_id) + 1 WHERE ROWID = new.group_id; END;
CREATE TRIGGER mark_message_unread AFTER UPDATE ON message WHEN old.flags = 2 AND NOT new.flags = 2 BEGIN UPDATE msg_group SET unread_count = (SELECT unread_count FROM msg_group WHERE ROWID = new.group_id) + 1 WHERE ROWID = new.group_id; END;
CREATE TRIGGER mark_message_read AFTER UPDATE ON message WHEN NOT old.flags = 2 AND new.flags = 2 BEGIN UPDATE msg_group SET unread_count = (SELECT unread_count FROM msg_group WHERE ROWID = new.group_id) - 1 WHERE ROWID = new.group_id; END;
CREATE TRIGGER delete_message AFTER DELETE ON message WHEN NOT old.flags = 2 BEGIN UPDATE msg_group SET unread_count = (SELECT unread_count FROM msg_group WHERE ROWID = old.group_id) - 1 WHERE ROWID = old.group_id; END;

"
  
  
  msg_id = 1
  @messages[1..-1].each do |msg_row|
    #statement = iosdb.prepare "INSERT INTO message (address, date, text, flags, group_id, country) VALUES (?, ?, ?, ?, ?, ?)"
    #result = statement.execute msg_row[msgcol("Sender")],
    #                           msg_row[msgcol("proper_time")],
    #                           msg_row[msgcol("Text")],
    #                           case msg_row[msgcol("Status")]
    #                             when 5 then 3
    #                             when 36 then 2
    #                           end,
    #                           1,
    #                           country
    
    address = utftoascii msg_row[msgcol("Sender")]
    
    # Skip these Windows Live things
    next if address == "+4560993100000"
    
    # Australia specific thingos
    if address.start_with? "+61"
      address.sub! "+61", "0"
    end
    if address.start_with? "0" and address.length == 10 # Mobile numbers
      address = address[0..3] + " " + address[4..6] + " " + address[7..9]
    end
    if address.length > 3 and address.length < 7 # iOS adds a space between the 3rd and 4th digit
      address = address[0..2] + " " + address[3..-1]
    end
    
    # Addresses/our group
    if not people.include? address
      people << address
    end
    group_id = (people.index address) + 1
    
    # Convert the flags
    flags = case msg_row[msgcol("Status")]
              when 5 then 3
              when 36 then 2
            end
    
    # Unix timestamp
    unixtimestamp = (DateTime.strptime(utftoascii(msg_row[msgcol("proper_time")]), "%Y-%m-%d %H:%M:%S")).to_time.to_i
    
    # And now let's make the query!
    string << "INSERT INTO message (ROWID, address, date, text, flags, group_id, country) VALUES (
#{msg_id},
\"#{address}\",
#{unixtimestamp}, -- #{utftoascii msg_row[msgcol("proper_time")]} (original db value)
\"#{(utftoascii msg_row[msgcol("Text")]).gsub('"', '""')}\",
#{flags},
#{group_id},
\"#{country}\");

"

    newest_message_for_person[address] = msg_id
    
    # Next message...
    msg_id += 1
  end
  
  group_id = 1
  people.each do |person|
    string << "INSERT INTO group_member (ROWID, group_id, address, country) VALUES (#{group_id}, #{group_id}, \"#{person}\", \"#{country}\");
"
    string << "INSERT INTO msg_group (ROWID, newest_message) VALUES (#{group_id}, #{newest_message_for_person[person]});
"
    group_id += 1
  end
  
  f = File.open("output.sql", "w") {|f| f.write string }
  
  puts "Bam, done!"
end

def first_stuff
  puts "Where is MDataStore.db3 located? Press enter to use the default of"
  puts "%LOCALAPPDATA%\\Nokia\\Nokia Data Store\\DataBase\\MDataStore.db3" # TODO: Detect OSX/etc. and behave accordingly
  puts
  mdatastore_location = gets.strip
  puts
  
  if mdatastore_location.empty?
    mdatastore_location = File.join ENV["localappdata"], "Nokia\\Nokia Data Store\\DataBase\\MDataStore.db3"
  end
  
  if not File.exists? mdatastore_location
    puts "The location you provided doesn't exist!"
    puts
    first_stuff
  else
    mdatastore_db = SQLite3::Database.new mdatastore_location
    
    # SQLite3::Database#execute2 returns the columns as the first row
    @messages = mdatastore_db.execute2 "SELECT *, datetime(SentReceivedTimestamp, '+6612.097260274 year') AS proper_time FROM MessageEx"
    puts "Found #{@messages.count-1} messages"
    
    if @messages.count == 1
      puts "So that means there's nothing to do... exiting!"
      return
    end
  
    puts
    
    convert_to_ios
  end
end

first_stuff