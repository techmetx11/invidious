require "sodium"
require "random"
require "base64"

POW_SIGNATURE_KEY = HMAC_KDF.derive("powsigna", 0, 64)
MAX_ITERATIONS = 20_000
MIN_ITERATIONS = 1_000
EXPIRY_TIME = 5 * 60
VISIT_EXPIRY_TIME = 10 * 60

struct PoWChallenge
  property salt : Bytes
  property target_hash : Bytes
  property signature : Bytes

  def initialize(@salt, @target_hash, @signature)
  end

  def self.new
    difficulty = Random.new.rand(MIN_ITERATIONS..MAX_ITERATIONS)

    salt = Random::Secure.random_bytes 32
    difficulty_bytes = Bytes.new sizeof(Int32)
    IO::ByteFormat::BigEndian.encode(difficulty, difficulty_bytes)

    target_hash = Sodium::Digest::Blake2b.new
    target_hash.update salt
    target_hash.update difficulty_bytes

    target_hash_digest = target_hash.final

    time = Time.utc.to_unix
    time_bytes = Bytes.new sizeof(Int64)
    IO::ByteFormat::BigEndian.encode(time, time_bytes)

    signature_hash = Sodium::Digest::Blake2b.new(key: POW_SIGNATURE_KEY)
    signature_hash.update salt
    signature_hash.update difficulty_bytes
    signature_hash.update time_bytes

    new(salt, target_hash_digest, signature_hash.final + time_bytes)
  end

  def to_str
    String.build do |str|
      str << Base64.strict_encode(self.salt)
      str << "."
      str << Base64.strict_encode(self.target_hash)
      str << "."
      str << Base64.strict_encode(self.signature)
    end
  end
end

struct PoWAnswer
  property salt : Bytes
  property difficulty : Int32
  property signature : Bytes

  def initialize(@salt, @difficulty, @signature)
  end

  def verify
    sig_io = IO::Memory.new self.signature
    sig_hash = Bytes.new Sodium::Digest::Blake2b::OUT_SIZE

    sig_io.read(sig_hash)
    time = sig_io.read_bytes(Int64, IO::ByteFormat::BigEndian)

    if (time + EXPIRY_TIME) < Time.utc.to_unix
      return false
    end

    difficulty_bytes = Bytes.new sizeof(Int32)
    IO::ByteFormat::BigEndian.encode(self.difficulty, difficulty_bytes)

    time_bytes = Bytes.new sizeof(Int64)
    IO::ByteFormat::BigEndian.encode(time, time_bytes)

    true_hash = Sodium::Digest::Blake2b.new(key: POW_SIGNATURE_KEY)
    true_hash.update self.salt
    true_hash.update difficulty_bytes
    true_hash.update time_bytes

    if true_hash.final != sig_hash
      return false
    end

    return true
  end

  def self.from_str(str)
    list = str.split('.')

    new(Base64.decode(list[0]), list[1].to_i, Base64.decode(list[2]))
  end
end

def generate_visit_cookie()
  time = Time.utc.to_unix
  time_bytes = Bytes.new sizeof(Int64)
  IO::ByteFormat::BigEndian.encode(time, time_bytes)

  digest = Sodium::Digest::Blake2b.new(key: POW_SIGNATURE_KEY)
  digest.update time_bytes

  return Base64.strict_encode(time_bytes + digest.final)
end

def verify_visit_cookie(cookie)
  puts cookie
  cookie_io = IO::Memory.new Base64.decode(cookie)

  digest = Bytes.new Sodium::Digest::Blake2b::OUT_SIZE
  time = cookie_io.read_bytes(Int64, IO::ByteFormat::BigEndian)
  cookie_io.read(digest)

  if (time + VISIT_EXPIRY_TIME) < Time.utc.to_unix
    return false
  end

  time_bytes = Bytes.new sizeof(Int64)
  IO::ByteFormat::BigEndian.encode(time, time_bytes)

  true_hash = Sodium::Digest::Blake2b.new(key: POW_SIGNATURE_KEY)
  true_hash.update time_bytes

  if true_hash.final != digest
    return false
  end

  return true
end
