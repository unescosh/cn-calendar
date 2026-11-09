//! 最小 JSON 解析器（RFC 8259 子集，覆盖本项目全部数据文件）。
//! 零外部依赖，避免 crates.io 拉取与交叉编译负担。

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Value>),
    Object(Vec<(String, Value)>),
}

impl Value {
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(items) => items.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(s) => Some(s),
            _ => None,
        }
    }
    /// 只接受整数值。小数一律拒绝，避免把精度问题静默带进日期字段。
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Value::Number(n)
                if n.is_finite()
                    && n.fract() == 0.0
                    && *n >= i64::MIN as f64
                    && *n <= i64::MAX as f64 =>
            {
                Some(*n as i64)
            }
            _ => None,
        }
    }
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            _ => None,
        }
    }
    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(a) => Some(a),
            _ => None,
        }
    }
    pub fn as_object(&self) -> Option<&[(String, Value)]> {
        match self {
            Value::Object(o) => Some(o),
            _ => None,
        }
    }
    pub fn get_str(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(Value::as_str)
    }
    pub fn get_i64(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(Value::as_i64)
    }
    pub fn get_bool(&self, key: &str) -> Option<bool> {
        self.get(key).and_then(Value::as_bool)
    }
    pub fn get_array(&self, key: &str) -> Option<&[Value]> {
        self.get(key).and_then(Value::as_array)
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }
    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.pos += 1;
        }
    }
    fn expect_bytes(&mut self, lit: &[u8]) -> Result<(), String> {
        if self.bytes.get(self.pos..self.pos + lit.len()) == Some(lit) {
            self.pos += lit.len();
            Ok(())
        } else {
            Err(format!("期望 {:?}，位置 {}", String::from_utf8_lossy(lit), self.pos))
        }
    }
    fn value(&mut self) -> Result<Value, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => self.string().map(Value::String),
            Some(b't') => {
                self.expect_bytes(b"true")?;
                Ok(Value::Bool(true))
            }
            Some(b'f') => {
                self.expect_bytes(b"false")?;
                Ok(Value::Bool(false))
            }
            Some(b'n') => {
                self.expect_bytes(b"null")?;
                Ok(Value::Null)
            }
            Some(c) if c == b'-' || c.is_ascii_digit() => self.number(),
            other => Err(format!("无法解析的值，位置 {}，字节 {:?}", self.pos, other)),
        }
    }
    fn object(&mut self) -> Result<Value, String> {
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Object(items));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(format!("对象键应为字符串，位置 {}", self.pos));
            }
            let key = self.string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(format!("对象缺少冒号，位置 {}", self.pos));
            }
            self.pos += 1;
            let value = self.value()?;
            items.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(items));
                }
                _ => return Err(format!("对象缺少逗号或右括号，位置 {}", self.pos)),
            }
        }
    }
    fn array(&mut self) -> Result<Value, String> {
        self.pos += 1;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                _ => return Err(format!("数组缺少逗号或右括号，位置 {}", self.pos)),
            }
        }
    }
    fn hex4(&mut self) -> Result<u16, String> {
        if self.pos + 4 > self.bytes.len() {
            return Err(format!("\\u 转义不完整，位置 {}", self.pos));
        }
        let mut v: u16 = 0;
        for _ in 0..4 {
            let c = self.bytes[self.pos];
            let d = match c {
                b'0'..=b'9' => c - b'0',
                b'a'..=b'f' => c - b'a' + 10,
                b'A'..=b'F' => c - b'A' + 10,
                _ => return Err(format!("非法 \\u 转义，位置 {}", self.pos)),
            };
            v = v * 16 + d as u16;
            self.pos += 1;
        }
        Ok(v)
    }
    fn string(&mut self) -> Result<String, String> {
        self.pos += 1; // 跳过起始引号
        let mut out: Vec<u8> = Vec::new();
        loop {
            let c = self.peek().ok_or_else(|| format!("字符串未闭合，位置 {}", self.pos))?;
            self.pos += 1;
            match c {
                b'"' => {
                    return String::from_utf8(out)
                        .map_err(|e| format!("字符串非 UTF-8：{}", e));
                }
                b'\\' => {
                    let esc = self.peek().ok_or("转义符后无内容")?;
                    self.pos += 1;
                    match esc {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'b' => out.push(8),
                        b'f' => out.push(12),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        b'u' => {
                            let hi = self.hex4()?;
                            let codepoint: u32 = if (0xD800..=0xDBFF).contains(&hi) {
                                if self.bytes.get(self.pos..self.pos + 2) == Some(b"\\u") {
                                    self.pos += 2;
                                    let lo = self.hex4()?;
                                    if !(0xDC00..=0xDFFF).contains(&lo) {
                                        return Err("非法代理对".into());
                                    }
                                    0x10000 + (((hi as u32 - 0xD800) << 10) | (lo as u32 - 0xDC00))
                                } else {
                                    return Err("高位代理后缺少低位代理".into());
                                }
                            } else {
                                hi as u32
                            };
                            let ch = char::from_u32(codepoint).ok_or("非法码点")?;
                            let mut buf = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                        }
                        _ => return Err(format!("未知转义 \\{}，位置 {}", esc as char, self.pos)),
                    }
                }
                _ => out.push(c),
            }
        }
    }
    fn number(&mut self) -> Result<Value, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.pos += 1;
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
                self.pos += 1;
            }
        }
        let s = std::str::from_utf8(&self.bytes[start..self.pos]).map_err(|e| e.to_string())?;
        let n: f64 = s.parse().map_err(|_| format!("非法数字 {}，位置 {}", s, start))?;
        Ok(Value::Number(n))
    }
}

pub fn parse(input: &str) -> Result<Value, String> {
    let mut p = Parser {
        bytes: input.as_bytes(),
        pos: 0,
    };
    let v = p.value()?;
    p.skip_ws();
    if p.pos != p.bytes.len() {
        return Err(format!("JSON 结束后仍有字符，位置 {}", p.pos));
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parse_all_types() {
        let v = parse(r#"{"a":1,"b":-2.5,"e":-2,"c":[true,false,null,"中文"],"d":"x\ny"}"#).unwrap();
        assert_eq!(v.get_i64("a"), Some(1));
        assert_eq!(v.get("b").unwrap().as_i64(), None);
        assert_eq!(v.get_i64("e"), Some(-2));
        assert_eq!(v.get_array("c").unwrap().len(), 4);
        assert_eq!(v.get_array("c").unwrap()[3].as_str(), Some("中文"));
        assert_eq!(v.get_str("d"), Some("x\ny"));
    }
    #[test]
    fn parse_unicode_escape() {
        let v = parse(r#""\u4e2d\u6587""#).unwrap();
        assert_eq!(v.as_str(), Some("中文"));
    }
    #[test]
    fn reject_broken() {
        assert!(parse(r#"{"a":}"#).is_err());
        assert!(parse("[1,2,]").is_err());
        assert!(parse("{} trailing").is_err());
    }
}
