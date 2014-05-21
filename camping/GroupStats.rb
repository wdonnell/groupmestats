require 'sqlite3'
require 'json'
require 'yaml'
require 'pp'

Camping.goes :GroupStats
if !ARGV[1].nil?
    $config_file = ARGV[1]
else
    $config_file = 'web.yaml'
end

def GroupStats.create
	puts "creating db connection"
	begin 
		config = YAML.load_file($config_file)
	rescue
		abort('Configuration file not found.  Exiting...')
	end

	begin
		$database = SQLite3::Database.new( config['groupme']['database'] ) #name your db as db.sqlite3 and put it in the same folder as this file
	rescue
		abort('Did not specify a valid database file')
	end
end

module GroupStats::Controllers
  class Index < R '/'
    def get
       begin 
         config = YAML.load_file($config_file)
       rescue
         abort('Configuration file not found.  Exiting...')
       end
       File.open(File.join(File.expand_path(File.dirname(__FILE__)), 'index.html') )
    end
  end
  
  class GroupList < R '/rest/grouplist'
	def get()
		result = $database.execute("select * from groups")
		headers["Content-Type"] = "application/json"
		return result.to_json
	end
  end
  
  class PostsMost < R '/rest/postsmost'
    def get()
		if(@input.days == nil)
			@input.days = "9999999999"
		end
		if(@input.groupid == nil)
			@status = 400
			return 'need group id'
		end
		
		result = $database.execute( "SELECT user_groups.Name, count(messages.user_id) as count FROM user_groups left join messages on messages.user_id = user_groups.user_id WHERE messages.created_at > datetime('now', ?) AND messages.group_id=? AND user_groups.group_id=? group by messages.user_id order by count desc",
		"-" + @input.days + " day",
		@input.groupid,
        @input.groupid)
		headers['Content-Type'] = "application/json"
		return result.to_json
    end
  end
end

module GroupStats::Views
  #not using
end
