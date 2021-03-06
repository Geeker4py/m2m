# -*- coding: utf-8 -*-

#将markdown发送为邮件
require 'mail'
require_relative './scan'
require_relative './compiler'
require_relative './util'
require_relative './store'
require_relative './setup'

class Mailer
	def initialize
		@util = Util.instance
		@mail_config = Setup.instance.get_merged_config['mail']
		#检查邮件的配置信息
		Setup.instance.check_mail_setup

		#扫描所有文件
        scan = Scan.new
        scan.execute

        @store = Store.new scan.files
        @compiler = Compiler.new
	end

	#添加附件, 并返回替换后的body
	def add_pictures(mail, article, body)
    	images = body.scan(/<img.+src=["'](.+?)['"]/i)
    	return body if images.length == 0

    	root = Pathname.new File::dirname(article['file'])
    	#去重，并去掉非相对路径的
    	list = Hash.new
    	images.each { | line |
    		image = line[0]
    		next if not /^[\.\/]/ =~ image

    		#将全路径作为key，达到去重的效果
    		file = (root + Pathname.new(image)).to_s
    		list[file] = image
    	}

    	#遍历所有图片，添加到附件
    	list.each do |file, src|
    		mail.add_file file
    		cid = mail.attachments.last.cid
    		body = body.gsub(src, 'CID:' + cid)
    	end

    	body
	end

	#添加邮件的主体内容，包括body/处理附件等
	def add_content(mail, article)
		#获取body的内容
		data = {
			"article" => article
		}
		body = @compiler.execute 'mail', data, false
		body = body + self.get_ad

		#分析出图片列表
		body = self.add_pictures mail, article, body

		#添加邮件的HTML内容
		mail.html_part = Mail::Part.new do
		  content_type 'text/html; charset=UTF-8'
		  body body
		end
	end

	#获取用户的密码，如果用户使用了密码进行加密，则提示用户输入密钥
	def get_password
		safer = @mail_config['safer']
		password = @mail_config['password']

		encrypt_key = nil
		if safer
			message = "请输入加密您密码的钥匙"
			encript_key = ask(message, String){|q| 
				q.echo = '*'
			}
		end

		@util.decrypt password, encript_key
	end

	#设置邮件的默认配置
	def set_mail_defaults
		smtp_server = @mail_config['smtp_server']
		port = @mail_config['port']
		username = @mail_config['username']
		ssl = @mail_config['ssl'] == 'y'
		password = self.get_password

        #配置邮件参数
		Mail.defaults do
		  delivery_method :smtp, {
		  	:address => smtp_server,
		  	:port => port,
		  	:user_name => username,
		  	:password => password,
		  	:ssl => ssl,
		  	:enable_starttls_auto => true
		  }
		end
	end

	#添加广告
	def get_ad()
		<<EOF
<div class="product" style="background-color: rgba(204, 204, 204, 0.26);padding: 4px 10px; text-align: right; font-size: 12px;">
	本邮件由
	<a href="https://github.com/wvv8oo/m2m" target="_blank">m2m</a>
	根据Markdown自动转换并发送
</div>
EOF
	end

	#获取邮件接收人
	def get_to(to, article)
		meta = article['meta']

		#优先取meta中的to
		to = meta['to'] if not to and meta['to'] 
		#如果meta没有to，且用户也没有指定to，则使用
		to = @mail_config['to'] if not to
		#依然没有找到收件人
		return @util.error '邮件接收人无效，可使用-a参数指定收件人' if not to

		to = [to] if to.class == String
		to
	end

	#获取将要发送的markdown文件
	def get_article(md_file)
		items = @store.get_children()
		return @util.error '没有找到任何的Markdown文件' if items.length == 0

		#如果用户没有指定, 则取最新的
		return @store.articles[items[0]] if not md_file

		special_article = nil
		index = 0
		begin
			key = items[index]
			article = @store.articles[key]
			file = article['file']
			relative_path = @util.get_relative_path file, @util.workbench

			special_article = article if relative_path == md_file


			index += 1
		end while special_article == nil and index < items.length

		@util.error "当前目录下未找到Markdown文件 => #{md_file}" if not special_article
		return special_article
	end

	#优先读取用户指定的，然后读取文章中指定的subject，再读取配置文件中的
	def get_subject(subject, article)
		meta = article['meta']
		#读取文章中mate的，如果在命令行没有指定主题
		subject = meta['subject'] if not subject and meta['subject']
		
		#文章中没有，则使用配置文件中的
		subject = @mail_config['subject'] if not subject

		#配置文件也没有，则使用title，article无论如何都会有title的
		subject = meta['title'] if not subject

		self.covert_date_macro subject
	end

	def get_from
		from = @mail_config['from']
		from = @mail_config['account'] if not from
		from
	end

	#将标题中的日期宏，转换为对应的日期
	def covert_date_macro(subject)
		format = @mail_config['format'] || '%Y-%m-%d'
		subject = subject.gsub('$now', Date.today.strftime(format))
		subject = subject.gsub('$last_week', (Date.today - 7).strftime(format))
		subject
	end

	#警示用户，由用户确定是否发送
	def alarm(relative_path, subject, to)
		puts "您确定要发送这封邮件吗？"
		puts "邮件标题：#{subject}"
		puts "Markdown：#{relative_path}"
		puts "收件人：#{to}"
		puts ""

		#提示用户是否需要发送
	    result = ask("确认发送请按y或者回车，取消请按其它键", lambda { |yn| yn.downcase[0] == ?y or yn == ''})

		@util.error '您中止了邮件的发送' if not result
	end

	#发送邮件
	def send(to, md_file, subject, silent = false)
		article = self.get_article md_file

		from = self.get_from
		to = self.get_to to, article
		subject = self.get_subject subject, article

		relative_path = @util.get_relative_path article['file'], @util.workbench

		#配置邮件信息
		self.set_mail_defaults

		#警示用户是否需要发送
		self.alarm relative_path, subject, to if not silent

		#创建一个mail的实例，以后再添加附件和html内容
		mail = Mail.new do
			from from
			to to
			subject subject
		end 

		self.add_content mail, article
	
		# @util.write_file './send.log', mail.parts.last.decoded
		mail.deliver

		puts "恭喜，您的邮件发送成功"
		puts "邮件标题：#{subject}"
		puts "Markdown：#{relative_path}"
		puts "收件人：#{to}"
	end
end